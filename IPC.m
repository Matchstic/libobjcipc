//
//  libobjcipc
//  IPC.m
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#import "IPC.h"
#import "Connection.h"
#import "Message.h"
#include "kern_memorystatus.h"

#define SERVER_PORT_KEY @"serverPort"
#define SERVER_PAUSED_KEY @"serverPaused"

/*
 Note: CFPreferences is used to synchronise state between server and clients when they are not connected
 */

static inline void socketServerCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
	
	if (type == kCFSocketAcceptCallBack) {
		
		// cast data to socket native handle
		CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *)data;
		
		// create pair with incoming socket handle
		[[OBJCIPC sharedInstance] _createPairWithAppSocket:nativeSocketHandle];
	}
}

static OBJCIPC *sharedInstance = nil;
static NSUInteger lastKnownServerPort = -1;
static BOOL lastKnownServerPauseState = NO;

static inline void preferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    
    // Reload settings to check what changed
    CFPreferencesAppSynchronize((__bridge CFStringRef)SERVER_ID);
    
    NSDictionary *settings;
    CFArrayRef keyList = CFPreferencesCopyKeyList((__bridge CFStringRef)SERVER_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keyList) {
        settings = [NSMutableDictionary dictionary];
    } else {
        CFDictionaryRef dictionary = CFPreferencesCopyMultiple(keyList, (__bridge CFStringRef)SERVER_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        
        settings = [(__bridge NSDictionary *)dictionary copy];
        CFRelease(dictionary);
        CFRelease(keyList);
    }
    
    NSNumber *port = settings[SERVER_PORT_KEY];
    NSNumber *paused = settings[SERVER_PAUSED_KEY];
    
    if (lastKnownServerPort != [port unsignedIntValue]) {
        IPCLOG(@"Server port has changed, reconnecting...");
        
        OBJCIPC *ipc = [OBJCIPC sharedInstance];
        ipc.activatedForReconnection = YES;
        
        // Reconnect to the new server port
        [OBJCIPC deactivate];
        [OBJCIPC activate];
    }
    
    if (lastKnownServerPauseState != [paused boolValue]) {
        // Pause state changed
        
        IPCLOG(@"Server pause state changed: %d", [paused boolValue]);
        
        if ([paused boolValue]) {
            // Paused server, disconnect
            [OBJCIPC deactivate];
        } else {
            // Restarted server, connect again
            
            OBJCIPC *ipc = [OBJCIPC sharedInstance];
            ipc.activatedForReconnection = YES;
            
            [OBJCIPC activate];
        }
        
        lastKnownServerPauseState = [paused boolValue];
    }
}

@implementation OBJCIPC

+ (BOOL)isServer {
	return ![self isApp];
}

+ (BOOL)isApp {
	return [[NSBundle mainBundle] bundleIdentifier] != nil;
}

+ (instancetype)sharedInstance {
	
	@synchronized(self) {
		if (sharedInstance == nil)
			[self new];
	}
	
	return sharedInstance;
}

+ (id)allocWithZone:(NSZone *)zone {
	
	@synchronized(self) {
		if (sharedInstance == nil) {
			sharedInstance = [super allocWithZone:zone];
			return sharedInstance;
		}
	}
	
	return nil;
}

+ (void)activate {
	
	OBJCIPC *ipc = [self sharedInstance];
	if (ipc.activated) return; // only activate once
	
	IPCLOG(@"Activating OBJCIPC");
	
	if ([self isServer]) {
	
		// create socket server
		ipc.serverPort = [ipc _createSocketServer];
		      
        // Write to CFPreferences
        CFPreferencesSetValue ((__bridge CFStringRef)SERVER_PORT_KEY, (__bridge CFPropertyListRef)@(ipc.serverPort), (__bridge CFStringRef)SERVER_ID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
        
        CFPreferencesAppSynchronize((__bridge CFStringRef)SERVER_ID);
        
        // Post notification that the serverPort has changed
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), SETTINGS_NOTIFICATION, NULL, NULL, YES);
		
	} else if ([self isApp]) {
		
		// get the port number of socket server
        CFPreferencesAppSynchronize((__bridge CFStringRef)SERVER_ID);
        
        NSDictionary *settings;
        CFArrayRef keyList = CFPreferencesCopyKeyList((__bridge CFStringRef)SERVER_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (!keyList) {
            settings = [NSMutableDictionary dictionary];
        } else {
            CFDictionaryRef dictionary = CFPreferencesCopyMultiple(keyList, (__bridge CFStringRef)SERVER_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            
            settings = [(__bridge NSDictionary *)dictionary copy];
            CFRelease(dictionary);
            CFRelease(keyList);
        }
        
        // Add preferences observer to cause a re-connection to the server
        CFNotificationCenterRef r = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(r, NULL, preferencesChangedCallback, SETTINGS_NOTIFICATION, NULL, 0);
        
		NSNumber *port = settings[SERVER_PORT_KEY];
		
		if (port == nil) {
			IPCLOG(@"Unable to retrieve server port from preference file");
			return;
		}
		
		ipc.serverPort = [port unsignedIntegerValue];
        lastKnownServerPort = [port unsignedIntegerValue];
		
		IPCLOG(@"Retrieved server port: %u", (unsigned int)ipc.serverPort);
		
		// make a persistent connection to server
		[ipc _connectToServer];
	}
	
	// update the activated flag
	ipc.activated = YES;
}

+ (void)deactivate {
	
	if (![self isApp]) {
		IPCLOG(@"You can only deactivate OBJCIPC in app");
		return;
	}
	
	OBJCIPC *ipc = [self sharedInstance];
	if (!ipc.activated) return; // not activated yet
	
	IPCLOG(@"Deactivating OBJCIPC");
	
	// close all connections (normally only with server)
	for (OBJCIPCConnection *connection in ipc.pendingConnections) {
		[connection closeConnection];
	}
	
	NSMutableDictionary *activeConnections = ipc.activeConnections;
	for (NSString *identifier in activeConnections) {
		OBJCIPCConnection *connection = [activeConnections objectForKey:identifier];
		[connection closeConnection];
	}
	
	// release all pending and active connections
    [ipc.pendingConnections removeAllObjects];
	ipc.pendingConnections = nil;
    
    [ipc.activeConnections removeAllObjects];
	ipc.activeConnections = nil;
	
	// reset all other instance variables
	ipc.serverPort = 0;
	ipc.outgoingMessageQueue = nil;
	
	// update the activated flag
	ipc.activated = NO;
}

+ (void)pauseServer {
    if ([self isApp]) {
        IPCLOG(@"Only server can call this");
        return;
    }
    
    [self _sendServerIsPaused:YES];
}

+ (void)restartServer {
    if ([self isApp]) {
        IPCLOG(@"Only server can call this");
        return;
    }
    
    [self _sendServerIsPaused:NO];
}

+ (void)_sendServerIsPaused:(BOOL)isPaused {
    IPCLOG(@"<IPC> Set server pause state: %d", isPaused);
    
    // Write to CFPreferences
    CFPreferencesSetValue ((__bridge CFStringRef)SERVER_PAUSED_KEY, (__bridge CFPropertyListRef)@(isPaused), (__bridge CFStringRef)SERVER_ID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    
    CFPreferencesAppSynchronize((__bridge CFStringRef)SERVER_ID);
    
    // Post notification of thing has changed
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), SETTINGS_NOTIFICATION, NULL, NULL, YES);
}

+ (void)broadcastMessageToAppsWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)handler {
    OBJCIPC *ipc = [self sharedInstance];
    
    // construct an outgoing message
    // message identifier will be assigned in OBJCIPCConnection
    OBJCIPCMessage *message = [OBJCIPCMessage outgoingMessageWithMessageName:messageName dictionary:dictionary messageIdentifier:nil isReply:NO replyHandler:handler];
    
    [ipc queueOutgoingBroadcastMessage:message];
}

+ (BOOL)sendMessageToAppWithIdentifier:(NSString *)identifier messageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)handler {
	
	IPCLOG(@"Current thread: %@", [NSThread currentThread]);
	
	if (![self isServer] && ![identifier isEqualToString:SERVER_ID]) {
		IPCLOG(@"You must send messages to app <%@> in server", identifier);
		return NO;
	}
	
	if (identifier == nil) {
		IPCLOG(@"App identifier cannot be nil");
		return NO;
	}
	
	if (messageName == nil) {
		IPCLOG(@"Message name cannot be nil");
		return NO;
	}
	
	IPCLOG(@"Ready to send message to app with identifier <%@> <message name: %@> <dictionary: %@>", identifier, messageName, dictionary);
	
	OBJCIPC *ipc = [self sharedInstance];
	
	// construct an outgoing message
	// message identifier will be assigned in OBJCIPCConnection
	OBJCIPCMessage *message = [OBJCIPCMessage outgoingMessageWithMessageName:messageName dictionary:dictionary messageIdentifier:nil isReply:NO replyHandler:handler];
	[ipc queueOutgoingMessage:message forAppWithIdentifier:identifier];
	
	return YES;
}

+ (BOOL)sendMessageToServerWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)replyHandler {
	
	if (![self isApp]) {
		IPCLOG(@"You must send messages to server in app");
		return NO;
	}
	
	return [self sendMessageToAppWithIdentifier:SERVER_ID messageName:messageName dictionary:dictionary replyHandler:replyHandler];
}

+ (NSDictionary *)sendMessageToAppWithIdentifier:(NSString *)identifier messageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary {
	
	__block BOOL received = NO;
	__block NSDictionary *reply = nil;
	
	BOOL success = [self sendMessageToAppWithIdentifier:identifier messageName:messageName dictionary:dictionary replyHandler:^(NSDictionary *dictionary) {
		received = YES;
		reply = [dictionary copy]; // must keep a copy in stack
	}];
	
	if (!success) return nil;
	
	// this loop is to wait until the reply arrives or the connection is closed (reply with nil value)
	while (!received) {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, YES); // 1000 ms
	}
	
    return reply;
}

+ (NSDictionary *)sendMessageToServerWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary {
	
	if (![self isApp]) {
		IPCLOG(@"You must send messages to server in app");
		return nil;
	}
	
	return [self sendMessageToAppWithIdentifier:SERVER_ID messageName:messageName dictionary:dictionary];
}

+ (void)registerIncomingMessageFromAppHandlerForMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler {
	[self registerIncomingMessageHandlerForAppWithIdentifier:nil andMessageName:messageName handler:handler];
}

+ (void)unregisterIncomingMessageFromAppHandlerForMessageName:(NSString *)messageName {
	[self unregisterIncomingMessageHandlerForAppWithIdentifier:nil andMessageName:messageName];
}

+ (void)registerIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier andMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler {
	
	if (messageName == nil) {
		IPCLOG(@"Message name cannot be nil when setting incoming message handler");
		return;
	}
	
	// activate OBJCIPC
	// OBJCIPC will be activated in app automatically when the app registers an incoming message handler
	[self activate];
	
	IPCLOG(@"Register incoming message handler for app with identifier <%@> and message name <%@>", identifier, messageName);
	
	OBJCIPC *ipc = [self sharedInstance];
	OBJCIPCConnection *connection = [ipc activeConnectionWithAppWithIdentifier:identifier];
	
	if (ipc.incomingMessageHandlers == nil) {
		ipc.incomingMessageHandlers = [NSMutableDictionary dictionary];
	}
	
	if (ipc.globalIncomingMessageHandlers == nil) {
		ipc.globalIncomingMessageHandlers = [NSMutableDictionary dictionary];
	}
	
	NSMutableDictionary *incomingMessageHandlers = ipc.incomingMessageHandlers;
	NSMutableDictionary *globalIncomingMessageHandlers = ipc.globalIncomingMessageHandlers;
	
	// copy the handler block
    handler = [handler copy];
	
	// save the handler
	if (identifier == nil) {
		
		if (handler != nil) {
			globalIncomingMessageHandlers[messageName] = handler;
		} else {
			[globalIncomingMessageHandlers removeObjectForKey:messageName];
		}
		
	} else {
		
		if (handler != nil) {
			
			if (incomingMessageHandlers[identifier] == nil) {
				incomingMessageHandlers[identifier] = [NSMutableDictionary dictionary];
			}
			
			NSMutableDictionary *incomingMessageHandlersForApp = incomingMessageHandlers[identifier];
			incomingMessageHandlersForApp[messageName] = handler;
			
		} else {
			// remove handler for a specific app identifier and message name
			NSMutableDictionary *incomingMessageHandlersForApp = incomingMessageHandlers[identifier];
			[incomingMessageHandlersForApp removeObjectForKey:messageName];
		}
		
		if (connection != nil) {
			// update handler in the active connection
			[connection setIncomingMessageHandler:handler forMessageName:messageName];
		}
	}
}

+ (void)unregisterIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier andMessageName:(NSString *)messageName {
	[self registerIncomingMessageHandlerForAppWithIdentifier:identifier andMessageName:messageName handler:nil];
}

+ (void)registerIncomingMessageFromServerHandlerForMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler {
	[self registerIncomingMessageHandlerForAppWithIdentifier:SERVER_ID andMessageName:messageName handler:handler];
}

+ (void)unregisterIncomingMessageFromServerHandlerForMessageName:(NSString *)messageName {
	[self registerIncomingMessageFromServerHandlerForMessageName:messageName handler:nil];
}

#define TEST_MESSAGE_NAME @"test.message.name"

+ (void)registerTestIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier {
	OBJCIPCIncomingMessageHandler handler = ^(NSDictionary *dictionary, void (^callback)(NSDictionary* response)) {
		//[self deactivate];
		IPCLOG(@"Received test incoming message <%@>", dictionary);
		callback(@{ @"testReplyKey": @"testReplyValue" });
	};
	[self registerIncomingMessageHandlerForAppWithIdentifier:identifier andMessageName:TEST_MESSAGE_NAME handler:handler];
}

+ (void)registerTestIncomingMessageHandlerForServer {
	[self registerTestIncomingMessageHandlerForAppWithIdentifier:SERVER_ID];
}

+ (void)sendAsynchronousTestMessageToAppWithIdentifier:(NSString *)identifier {
	NSDictionary *dict = @{ @"testKey": @"testValue" };
	NSDate *start = [NSDate date];
	OBJCIPCReplyHandler handler = ^(NSDictionary *dictionary) {
		NSTimeInterval time = [[NSDate date] timeIntervalSinceDate:start];
		IPCLOG(@"Received asynchronous test reply <%@>", dictionary);
		IPCLOG(@"Asynchronous message delivery spent ~%.4f ms", time * 1000);
	};
	[self sendMessageToAppWithIdentifier:identifier messageName:TEST_MESSAGE_NAME dictionary:dict replyHandler:handler];
}

+ (void)sendAsynchronousTestMessageToServer {
	[self sendAsynchronousTestMessageToAppWithIdentifier:SERVER_ID];
}

- (instancetype)init {
    self = [super init];
    
    if (self) {        
        // Setup UIKit listeners
        if ([OBJCIPC isApp]) {
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                        selector:@selector(applicationDidEnterBackground:)
                                                            name:@"UIApplicationDidEnterBackgroundNotification"
                                                          object:nil];
            
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                    selector:@selector(applicationDidEnterForeground:)
                                                        name:@"UIApplicationDidEnterForegroundNotification"
                                                      object:nil];
        }
    }
    
    return self;
}

- (OBJCIPCConnection *)activeConnectionWithAppWithIdentifier:(NSString *)identifier {
	return _activeConnections[identifier];
}

- (void)addPendingConnection:(OBJCIPCConnection *)connection {
	if (_pendingConnections == nil) _pendingConnections = [NSMutableSet new];
	if (![_pendingConnections containsObject:connection]) {
		[_pendingConnections addObject:connection];
	}
}

- (void)notifyConnectionBecomesActive:(OBJCIPCConnection *)connection {
	
	NSString *appIdentifier = connection.appIdentifier;
	if (appIdentifier == nil) {
		IPCLOG(@"App identifier cannot be nil");
		return;
	}
	
    // If a connection on the same app identifier arrives, swap to the new one
	if (_activeConnections[appIdentifier] != nil) {
		IPCLOG(@"The connection is already active, resetting");
        
        OBJCIPCConnection *existingConnection = _activeConnections[appIdentifier];
        
        [existingConnection closeConnection];
        [self removeConnection:existingConnection];
	}
	
	IPCLOG(@"Connection becomes active <%@>", connection);
	
	if (_activeConnections == nil) _activeConnections = [NSMutableDictionary new];
	
	// add it to the active connection list
	_activeConnections[appIdentifier] = connection;
	
	// remove it from the pending connection list
	[_pendingConnections removeObject:connection];
	
	// set its incoming message handler
	NSDictionary *handlers = _incomingMessageHandlers[appIdentifier];
	if (handlers != nil) {
		for (NSString *messageName in handlers) {
			OBJCIPCIncomingMessageHandler handler = handlers[messageName];
			[connection setIncomingMessageHandler:handler forMessageName:messageName];
		}
	}
	
	// pass the queued messages to the active connection
	NSArray *queuedMessages = _outgoingMessageQueue[appIdentifier];
	if (queuedMessages != nil && [queuedMessages count] > 0) {
		
		// pass the queued messages to the connection one by one
		for (OBJCIPCMessage *message in queuedMessages) {
			IPCLOG(@"Pass a queued message to the active connection <message: %@>", message);
			// send the message
			[connection sendMessage:message];
		}
		
		// remove the message queue
		[_outgoingMessageQueue removeObjectForKey:appIdentifier];
	}
    
    // Call reconnection handler if necessary
    if (self.activatedForReconnection) {
        if (self.reconnectionHandler) {
            self.reconnectionHandler();
        }
        
        self.activatedForReconnection = NO;
    }
}

- (void)notifyConnectionIsClosed:(OBJCIPCConnection *)connection {
	IPCLOG(@"Connection is closed <%@>", connection);
	
	[self removeConnection:connection];
}

- (void)removeConnection:(OBJCIPCConnection *)connection {
	
	IPCLOG(@"Remove connection <%@>", connection);
	
	if ([_pendingConnections containsObject:connection]) {
		// remove it from the pending connection list
		[_pendingConnections removeObject:connection];
	} else {
		// remove it from the active connection list
		NSString *identifier = connection.appIdentifier;
		if (identifier != nil) {
			IPCLOG(@"objcipc: Remove active connection <key: %@>", identifier);
			[_activeConnections removeObjectForKey:identifier];
		}
	}
}

- (void)queueOutgoingBroadcastMessage:(OBJCIPCMessage *)message {
    if (![OBJCIPC isServer]) {
        IPCLOG(@"Only server can broadcast messages");
        return;
    }
    
    NSArray *identifiers = [_activeConnections allKeys];
    
    for (NSString *identifier in identifiers) {
        [self queueOutgoingMessage:message forAppWithIdentifier:identifier];
    }
}

- (void)queueOutgoingMessage:(OBJCIPCMessage *)message forAppWithIdentifier:(NSString *)identifier {
	
	if (identifier == nil) {
		IPCLOG(@"App identifier cannot be nil");
		return;
	}
	
	OBJCIPCConnection *activeConnection = [self activeConnectionWithAppWithIdentifier:identifier];
	
	if (activeConnection == nil) {
		
		if (_outgoingMessageQueue == nil) {
			_outgoingMessageQueue = [NSMutableDictionary new];
		}
		
		// the connection with the app is not ready yet
		// so queue it up first
		NSMutableArray *existingQueue = _outgoingMessageQueue[identifier];
		
		// create a new queue for the given app identifier if it does not exist
		if (existingQueue == nil) existingQueue = [NSMutableArray array];
		
		// queue up the new outgoing message
		[existingQueue addObject:message];
		
		// update the queue
		_outgoingMessageQueue[identifier] = existingQueue;
		
	} else {
		
		// the connection with the app is ready
		// redirect the message to the active connection
		[activeConnection sendMessage:message];
	}
}

- (NSUInteger)_createSocketServer {
	
	if (![self.class isServer]) {
		IPCLOG(@"Socket server can only be created in server");
		return 0;
	}
    
    // Increase local memory limit to 50 MB
    int pid = (int)getpid();
    
    // call memorystatus_control
    memorystatus_memlimit_properties_t memlimit;
    memlimit.memlimit_active = 50;
    memlimit.memlimit_inactive = 50;
    
    int rc = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                                   pid,  // pid
                                   0,  // flags
                                   &memlimit,  // buffer
                                   sizeof(memlimit));  // buffersize
    IPCLOG(@"setting memory limit for pid: %d, with result: %d", pid, rc);
	
	// create socket server
	CFSocketRef socket = CFSocketCreate(NULL, AF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, &socketServerCallback, NULL);
	
	if (socket == NULL) {
		IPCLOG(@"Fail to create socket server");
		return 0;
	}
	
	int yes = 1;
	setsockopt(CFSocketGetNative(socket), SOL_SOCKET, SO_REUSEADDR, (void *)&yes, sizeof(yes));
	
	// setup socket address
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_len = sizeof(addr);
	addr.sin_family = AF_INET;
	addr.sin_port = htons(0);
	addr.sin_addr.s_addr = inet_addr("127.0.0.1");
	
	CFDataRef addrData = (__bridge CFDataRef)[NSData dataWithBytes:&addr length:sizeof(addr)];
	if (CFSocketSetAddress(socket, addrData) != kCFSocketSuccess) {
		IPCLOG(@"Fail to bind local address to socket server");
		CFSocketInvalidate(socket);
		CFRelease(socket);
		return 0;
	}
	
	// retrieve port number
	NSUInteger port = ntohs(((const struct sockaddr_in *)CFDataGetBytePtr(CFSocketCopyAddress(socket)))->sin_port);
	
	// configure run loop
	CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(NULL, socket, 0);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
	CFRelease(source);
	
	IPCLOG(@"Created socket server successfully <port: %u>", (unsigned int)port);
	
	return port;
}

- (void)_createPairWithAppSocket:(CFSocketNativeHandle)handle {
	
	IPCLOG(@"Creating pair with incoming socket connection from app");
	
	// setup pair and streams for incoming conneciton
	CFReadStreamRef readStream = NULL;
	CFWriteStreamRef writeStream = NULL;
	
	CFStreamCreatePairWithSocket(kCFAllocatorDefault, handle, &readStream, &writeStream);
	
	if (readStream == NULL || writeStream == NULL) {
		IPCLOG(@"Unable to create read and write streams");
		return;
	}
	
	IPCLOG(@"Created pair with incoming socket connection");
	
    NSInputStream *inputStream = (__bridge NSInputStream *)readStream;
    NSOutputStream *outputStream = (__bridge NSOutputStream *)writeStream;
	
	// create a new connection instance with the connected socket streams
	OBJCIPCConnection *connection = [[OBJCIPCConnection alloc] initWithInputStream:inputStream
                                                                      outputStream:outputStream];
	
	// it will become active after handshake with server
	[self addPendingConnection:connection];
}

- (void)_connectToServer {
	
	IPCLOG(@"Connecting to server at port %u", (unsigned int)_serverPort);
	
	// setup a new connection to socket server
	CFReadStreamRef readStream = NULL;
	CFWriteStreamRef writeStream = NULL;
	CFStreamCreatePairWithSocketToHost(NULL, CFSTR("127.0.0.1"), (unsigned int)_serverPort, &readStream, &writeStream);
	
	if (readStream == NULL || writeStream == NULL) {
		IPCLOG(@"Unable to create read and write streams");
		return;
	}
	
	IPCLOG(@"Connected to server");
	
    NSInputStream *inputStream = (__bridge NSInputStream *)readStream;
    NSOutputStream *outputStream = (__bridge NSOutputStream *)writeStream;
	
	// create a new connection
	OBJCIPCConnection *connection = [[OBJCIPCConnection alloc] initWithInputStream:inputStream
                                                                      outputStream:outputStream];
	connection.appIdentifier = SERVER_ID;
	
	// it will become active after handshake with server
	[self addPendingConnection:connection];
	
	// ask the connection to do handshake with server
	[connection _handshakeWithServer];
}

- (void)applicationDidEnterBackground:(NSNotification*)sender {
    IPCLOG(@"Sending application did enter background");
    [OBJCIPC deactivate];
}

- (void)applicationDidEnterForeground:(NSNotification*)sender {
    IPCLOG(@"Sending application did enter foreground");
    [OBJCIPC activate];
}

@end
