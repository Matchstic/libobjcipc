//
//  libobjcipc
//  Connection.m
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import <objc/runtime.h>
#import "Connection.h"
#import "IPC.h"
#import "Message.h"

#define MAX_CONTENT_LENGTH 1024

static char pendingIncomingMessageNameKey;
static char pendingIncomingMessageIdentifierKey;

@implementation OBJCIPCConnection

- (instancetype)initWithInputStream:(NSInputStream *)inputStream
                       outputStream:(NSOutputStream *)outputStream {
	
	if ((self = [super init])) {
		
		// set delegate
		inputStream.delegate = self;
		outputStream.delegate = self;
		
		// scheudle in run loop
		[inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
		[outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
		
		// open streams
		[inputStream open];
		[outputStream open];
		
		// keep references
		_inputStream = inputStream;
		_outputStream = outputStream;
	}
	
	return self;
}

- (void)sendMessage:(OBJCIPCMessage *)message {
	
	if (_closedConnection) return;
	
    // auto assign the next message identifier
    if (message.messageIdentifier == nil) {
        message.messageIdentifier = [self nextMessageIdentifier];
    }
    
    #if LOG_MESSAGE_BODY
        IPCLOG(@"<Connection> Send message to app with identifier <%@>", self.appIdentifier);
    #else
        IPCLOG(@"<Connection> Send message to app with identifier <%@> <message: %@>", self.appIdentifier, message);
    #endif
    
    OBJCIPCReplyHandler replyHandler = message.replyHandler;
    NSString *messageIdentifier = message.messageIdentifier;
    NSData *data = [message messageData];
    
    if (data == nil) {
        IPCLOG(@"<Connection> Unable to retrieve the message data");
        return;
    }
    
    // set reply handler
    if (replyHandler != nil) {
        if (self->_replyHandlers == nil) self->_replyHandlers = [NSMutableDictionary new];
        self->_replyHandlers[messageIdentifier] = replyHandler;
    }
    
    // Assure concurrency is sane
    dispatch_async(dispatch_get_main_queue(), ^{
        // append outgoing message data
        if (self->_outgoingMessageData == nil) self->_outgoingMessageData = [NSMutableData new];
        [self->_outgoingMessageData appendData:data];
        
        // write data to the output stream
        [self _writeOutgoingMessageData];
    });
}

- (void)closeConnection {
	
    if (_closedConnection) return;
    
    // Dispatch on the queue to ensure concurrency
    dispatch_async(dispatch_get_main_queue(), ^{
        IPCLOG(@"<Connection> Close connection <%@>", self);
        _closedConnection = YES;
        
        // reset all receiving message state
        [self _resetReceivingMessageState];
        
        // remove streams from run loop
        [_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [_outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        
        // close streams
        [_inputStream close];
        [_outputStream close];

        // Clear outgoing data queue
        _outgoingMessageData = nil;
        
        // reply nil messages to all reply listener
        if (_replyHandlers != nil && [_replyHandlers count] > 0) {
            for (NSString *key in _replyHandlers) {
                OBJCIPCReplyHandler handler = _replyHandlers[key];
                if (handler != nil) {
                    handler(nil);
                }
            }
        }
        
        // notify the main instance
        [[OBJCIPC sharedInstance] notifyConnectionIsClosed:self];
    });
}

- (void)setIncomingMessageHandler:(OBJCIPCIncomingMessageHandler)handler forMessageName:(NSString *)messageName {
	
	if (messageName == nil) {
		IPCLOG(@"<Connection> Message name cannot be nil when setting incoming message handler");
		return;
	}
	
	if (handler == nil) {
		[_incomingMessageHandlers removeObjectForKey:messageName];
	} else {
		if (_incomingMessageHandlers == nil) _incomingMessageHandlers = [NSMutableDictionary new];
		_incomingMessageHandlers[messageName] = handler;
	}
}

- (OBJCIPCIncomingMessageHandler)incomingMessageHandlerForMessageName:(NSString *)messageName {
	OBJCIPCIncomingMessageHandler appHandler = _incomingMessageHandlers[messageName];
	if (appHandler == nil) {
		return [OBJCIPC sharedInstance].globalIncomingMessageHandlers[messageName];
	} else {
		return appHandler;
	}
}

- (NSString *)nextMessageIdentifier {
	
	if (++_nextMessageIdentifier == 9999) {
		_nextMessageIdentifier = 0; // reset identifier
	}
	
	return [NSString stringWithFormat:@"%04d", (int)_nextMessageIdentifier];
}

- (void)_handshakeWithServer {
	
	if (_closedConnection) return;
	
	// retrieve the identifier of the current app
	NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
	
	// prepare a dictionary containing the bundle identifier
	NSDictionary *dict = @{ @"appIdentifier": identifier };
	OBJCIPCMessage *message = [OBJCIPCMessage handshakeMessageWithDictionary:dict];
	
	IPCLOG(@"<Connection> Send handshake message to server <app identifier: %@>", identifier);
	
	[self sendMessage:message];
}

- (void)_handshakeWithServerComplete:(NSDictionary *)dict {
	
	if (_closedConnection) return;
	
	BOOL success = [dict[@"success"] boolValue];
	if (success) {
		
		IPCLOG(@"<Connection> Handshake with server succeeded");
		
		// update flag
		_handshakeFinished = YES;
		
		// update app identifier
		self.appIdentifier = SERVER_ID;
		[[OBJCIPC sharedInstance] notifyConnectionBecomesActive:self];
		
		// dispatch all pending incoming messages to handler
		for (NSDictionary *dictionary in _pendingIncomingMessages) {
			#if LOG_MESSAGE_BODY
				IPCLOG(@"Dispatch a pending incoming message to handler <message: %@>", dictionary);
			#else
				IPCLOG(@"Dispatch a pending incoming message to handler");
			#endif
			[self _dispatchIncomingMessage:dictionary];
		}
		
		_pendingIncomingMessages = nil;
		
	} else {
		IPCLOG(@"<Connection> Handshake with server failed");
		// close connection if the handshake fails
		[self closeConnection];
	}
}

- (NSDictionary *)_handshakeWithApp:(NSDictionary *)dict {
	
	if (_closedConnection) return nil;
	
	NSString *appIdentifier = dict[@"appIdentifier"];
	if (appIdentifier == nil || [appIdentifier length] == 0) {
		IPCLOG(@"<Connection> Handshake with app failed (empty app identifier)");
		[self closeConnection];
		return @{ @"success": @(NO) };
	}
	
	IPCLOG(@"<Connection> Handshake with app succeeded <app identifier: %@>", appIdentifier);
	
	// update flag
	_handshakeFinished = YES;
	
	// update app identifier
	self.appIdentifier = appIdentifier;
	[[OBJCIPC sharedInstance] notifyConnectionBecomesActive:self];
	
	return @{ @"success": @(YES) };
}

/**
 *  Read incoming message data with the format specified below
 *
 *  [ Header ]
 *  PW (magic number)
 *  0/1 (reply flag)
 *  0000\0 (message identifier, for its reply)
 *  message length (in bytes)
 *
 *  [ Body ]
 *  message data
 */
- (void)_readIncomingMessageData {
	
	if (_closedConnection) return;
	
	if (![_inputStream hasBytesAvailable]) {
		IPCLOG(@"<Connection> Input stream has no bytes available");
		return;
	}
    
    dispatch_async(dispatch_get_main_queue(), ^{
	
        if (!self->_receivedHeader) {
            
            int headerSize = sizeof(OBJCIPCMessageHeader);
            NSUInteger readLen = MAX(0, headerSize - self->_receivedHeaderLength);
            uint8_t header[readLen];
            int headerLen = (int)[self->_inputStream read:header maxLength:readLen];
            self->_receivedHeaderLength += headerLen;

            // prevent unexpected error when reading from input stream
            if (headerLen <= 0) {
                [self closeConnection];
                return;
            }

            if (self->_receivedHeaderData == nil) self->_receivedHeaderData = [NSMutableData new];
            [self->_receivedHeaderData appendBytes:(const void *)header length:headerLen];
            
            if (self->_receivedHeaderLength == headerSize) {
                
                // complete header
                OBJCIPCMessageHeader header;
                [self->_receivedHeaderData getBytes:&header length:sizeof(OBJCIPCMessageHeader)];
                
                char *magicNumber = header.magicNumber;
                if (!(magicNumber[0] == 'P' && magicNumber[1] == 'W')) {
                    // unknown message
                    [self closeConnection];
                    return;
                }
                
                // reply flag
                BOOL isReply = header.replyFlag;
                
                // message name
                NSString *messageName = [[NSString alloc] initWithCString:header.messageName encoding:NSASCIIStringEncoding];
                
                // message identifier
                NSString *messageIdentifier = [[NSString alloc] initWithCString:header.messageIdentifier encoding:NSASCIIStringEncoding];
                
                BOOL isHandshake = NO;
                if ([messageIdentifier isEqualToString:@"00HS"]) { // fixed
                    // this is a handshake message
                    isHandshake = YES;
                }
                
                // message content length
                int contentLength = header.contentLength;
                
                // header
                self->_receivedHeader = YES;
                self->_receivedHeaderLength = 0;
                self->_isHandshake = isHandshake;
                self->_isReply = isReply;
                self->_messageName = [messageName copy];
                self->_messageIdentifier = [messageIdentifier copy];
                self->_receivedHeaderData = nil;
                
                // content
                self->_contentLength = contentLength;
                self->_receivedContentLength = 0;
                self->_receivedContentData = [NSMutableData new];
                
                IPCLOG(@"<Connection> Received message header <reply: %@> <identifier: %@> <message name: %@> <%d bytes>", (isReply ? @"YES" : @"NO"), messageIdentifier, messageName, contentLength);
                
            } else {
                // incomplete header
                self->_receivedHeader = NO;
                return;
            }
        }
        
        // message content
        if (self->_contentLength > 0) {
            NSUInteger len = MAX(MIN(MAX_CONTENT_LENGTH, self->_contentLength - self->_receivedContentLength), 0);
            uint8_t buffer[len];
            int receivedLen = (int)[self->_inputStream read:buffer maxLength:len];
            if (receivedLen > 0) {
                [self->_receivedContentData appendBytes:(const void *)buffer length:receivedLen];
                self->_receivedContentLength += receivedLen;
                if (self->_receivedContentLength == self->_contentLength) {
                    // finish receiving the message
                    [self _dispatchReceivedMessage];
                }
            }
        } else {
            // no data to receive because content length is 0 (most likely it is a empty reply)
            [self _dispatchReceivedMessage];
        }
    });
}

- (void)_writeOutgoingMessageData {
	
	if (_closedConnection) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger length = [_outgoingMessageData length];
        
        if (_outgoingMessageData != nil && _outgoingMessageData.bytes != nil && length > 0 && [_outputStream hasSpaceAvailable]) {
            
            NSUInteger len = MAX(MIN(MAX_CONTENT_LENGTH, length), 0);
            
            // copy the message data to buffer
            uint8_t buf[len];
            memcpy(buf, _outgoingMessageData.bytes, len);
            
            // write to output stream
            NSInteger writtenLen = [_outputStream write:(const uint8_t *)buf maxLength:len];
            
            // error occurs
            if (writtenLen == -1) {
                // close connection
                [self closeConnection];
                return;
            }
            
            if (writtenLen > 0) {
                if ((length - writtenLen) > 0) {
                    // trim the data
                    NSRange range = NSMakeRange(writtenLen, length - writtenLen);
                    NSMutableData *trimmedData = [[_outgoingMessageData subdataWithRange:range] mutableCopy];
                    // update buffered outgoing message data
                    _outgoingMessageData = trimmedData;
                } else {
                    // finish writing buffer
                    _outgoingMessageData = nil;
                }
            }
        }
    });
}

- (void)_dispatchReceivedMessage {
	
	if (_closedConnection) return;
	
	// flags
	BOOL isHandshake = _isHandshake;
	BOOL isReply = _isReply;
	
	// message name
	NSString *name = _messageName;
	
	// message identifier
	NSString *identifier = _messageIdentifier;
	
	// content length
	int length = _contentLength;
	
	// received data
	NSData *data = _receivedContentData;
	
	// a simple check
	if ([data length] != length) {
		IPCLOG(@"<Connection> Mismatch received data length");
		[self closeConnection];
		return;
	}
	
	// convert the data back to NSDictionary
	NSDictionary *dictionary = (NSDictionary *)[NSKeyedUnarchiver unarchiveObjectWithData:data];
	
	if (isHandshake) {
		
		#if LOG_MESSAGE_BODY
			IPCLOG(@"<Connection> Handling incoming handshake message <%@>", dictionary);
		#else
			IPCLOG(@"<Connection> Handling incoming handshake message");
		#endif
		
		// pass to internal handler
		if ([OBJCIPC isServer]) {
			NSDictionary *reply = [self _handshakeWithApp:dictionary];
			if (reply != nil) {
				// send a handshake completion message to app
				OBJCIPCMessage *message = [OBJCIPCMessage handshakeMessageWithDictionary:reply];
				[self sendMessage:message];
			}
		} else {
			[self _handshakeWithServerComplete:dictionary];
		}
		
	} else if (isReply) {
		
		#if LOG_MESSAGE_BODY
			IPCLOG(@"<Connection> Handling reply message <%@>", dictionary);
		#else
			IPCLOG(@"<Connection> Handling reply message");
		#endif
		
		// find the message reply handler
		OBJCIPCReplyHandler handler = _replyHandlers[identifier];
		if (handler != nil) {
            handler(dictionary);
			
			IPCLOG(@"<Connection> Passed the received dictionary to reply handler");
			
			// release the reply handler
			[_replyHandlers removeObjectForKey:identifier];
		}
		
	} else {
		
		#if LOG_MESSAGE_BODY
			IPCLOG(@"<Connection> Handling incoming message <%@>", dictionary);
		#else
			IPCLOG(@"<Connection> Handling incoming message");
		#endif
		
		// set associated object (message name and identifier)
        if (dictionary) {
            objc_setAssociatedObject(dictionary, &pendingIncomingMessageNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(dictionary, &pendingIncomingMessageIdentifierKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
		
		if (!_handshakeFinished) {
			// put the incoming message into pending incoming message list
			if (_pendingIncomingMessages == nil) _pendingIncomingMessages = [NSMutableArray new];
			// put it into the list
			[_pendingIncomingMessages addObject:dictionary];
		} else {
			// pass the dictionary to incoming message handler
			// and wait for its reply
			[self _dispatchIncomingMessage:dictionary];
		}
	}
	
	[self _resetReceivingMessageState];
}

- (void)_dispatchIncomingMessage:(NSDictionary *)dictionary {
	
	// get back the name
	NSString *name = objc_getAssociatedObject(dictionary, &pendingIncomingMessageNameKey);
	
	// get back the identifier
	NSString *identifier = objc_getAssociatedObject(dictionary, &pendingIncomingMessageIdentifierKey);
	
	// the reply dictionary
	
	// handler
	OBJCIPCIncomingMessageHandler handler = [self incomingMessageHandlerForMessageName:name];
	
	if (handler != nil) {
		IPCLOG(@"<Connection> Pass the received dictionary to incoming message handler");
        
        if (!_closedConnection) {
            handler(dictionary, ^(NSDictionary *reply) {
                // send reply as a new message
                OBJCIPCMessage *message = [OBJCIPCMessage outgoingMessageWithMessageName:name dictionary:reply messageIdentifier:identifier isReply:YES replyHandler:nil];
                [self sendMessage:message];
            });
        }

	} else {
		IPCLOG(@"<Connection> No incoming message handler found");
	}
}

- (void)_resetReceivingMessageState {
	
	// header
	_receivedHeader = NO;
	_receivedHeaderLength = 0;
	_isHandshake = NO;
	_isReply = NO;
	_messageName = nil;
    _messageIdentifier = nil;
	_receivedHeaderData = nil;
	
	// content
	_contentLength = 0;
	_receivedContentLength = 0;
	_receivedContentData = nil;
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
	
	switch(event) {
			
		case NSStreamEventNone:
		case NSStreamEventOpenCompleted:
			break;
			
		case NSStreamEventHasSpaceAvailable:
			IPCLOG(@"<Connection> NSStreamEventHasSpaceAvailable: %@", stream);
			if (stream == _outputStream) {
				// write queued messages
				[self _writeOutgoingMessageData];
			}
			break;
			
		case NSStreamEventHasBytesAvailable:
			IPCLOG(@"<Connection> NSStreamEventHasBytesAvailable: %@", stream);
			if (stream == _inputStream) {
				// read incoming messages
				[self _readIncomingMessageData];
			}
			break;
			
		case NSStreamEventErrorOccurred:
			IPCLOG(@"<Connection> NSStreamEventErrorOccurred: %@", stream);
			[self closeConnection];
			break;
			
		case NSStreamEventEndEncountered:
			IPCLOG(@"<Connection> NSStreamEventEndEncountered: %@", stream);
			[self closeConnection];
			break;
	}
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@ %p> <App identifier: %@> <Reply handlers: %d>", [self class], self, _appIdentifier, (int)[_replyHandlers count]];
}

@end
