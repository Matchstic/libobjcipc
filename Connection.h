//
//  libobjcipc
//  Connection.h
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import "header.h"

@interface OBJCIPCConnection : NSObject<NSStreamDelegate> {    
	BOOL _closedConnection;
	BOOL _handshakeFinished;
	NSString *_appIdentifier;
	NSUInteger _nextMessageIdentifier;
	
	// socket streams
	NSInputStream *_inputStream;
	NSOutputStream *_outputStream;
    
    // auto disconnect
    NSUInteger _autoDisconnectTimerTicks;
    NSTimer *_autoDisconnectTimer;
	
	// header
	BOOL _receivedHeader;
	int _receivedHeaderLength;
	BOOL _isHandshake;
	BOOL _isReply;
	NSString *_messageIdentifier;
	NSString *_messageName;
	NSMutableData *_receivedHeaderData;
	
	// content
	int _contentLength;
	int _receivedContentLength;
	NSMutableData *_receivedContentData;
	
	// temporary storage of outgoing message data
	NSMutableData *_outgoingMessageData;
	
	// pending incoming messages (received earlier than handshake)
	NSMutableArray *_pendingIncomingMessages;
	
	// incoming message handler
	NSMutableDictionary *_incomingMessageHandlers;
	NSMutableDictionary *_replyHandlers;
}

@property(nonatomic, copy) NSString *appIdentifier;
@property(nonatomic, readonly) NSMutableDictionary *incomingMessageHandlers;
@property(nonatomic, strong) NSMutableDictionary *replyHandlers;

- (instancetype)initWithInputStream:(NSInputStream *)inputStream
                       outputStream:(NSOutputStream *)outputStream;

- (void)sendMessage:(OBJCIPCMessage *)message;
- (void)closeConnection;
- (void)setIncomingMessageHandler:(OBJCIPCIncomingMessageHandler)handler forMessageName:(NSString *)messageName;
- (OBJCIPCIncomingMessageHandler)incomingMessageHandlerForMessageName:(NSString *)messageName;
- (NSString *)nextMessageIdentifier;

// handshake with app and server
- (void)_handshakeWithServer;
- (void)_handshakeWithServerComplete:(NSDictionary *)dict;
- (NSDictionary *)_handshakeWithApp:(NSDictionary *)dict;

// message data transmission
- (void)_readIncomingMessageData;
- (void)_writeOutgoingMessageData;
- (void)_dispatchReceivedMessage;
- (void)_dispatchIncomingMessage:(NSDictionary *)dictionary;
- (void)_resetReceivingMessageState;

@end
