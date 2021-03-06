//
//  libobjcipc
//  IPC.h
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import "header.h"

@interface OBJCIPC : NSObject {
	
	BOOL _activated;
	
	// Server port
	NSUInteger _serverPort;
	
	// store active connections (each contains its own streams)
	NSMutableSet *_pendingConnections;
	NSMutableDictionary *_activeConnections;
	
	// message handlers and queues
	NSMutableDictionary *_globalIncomingMessageHandlers;
	NSMutableDictionary *_incomingMessageHandlers;
	NSMutableDictionary *_outgoingMessageQueue;
}

@property(nonatomic) BOOL activated;
@property(nonatomic) BOOL activatedForReconnection;
@property(nonatomic) NSUInteger serverPort;
@property(nonatomic, copy) void (^reconnectionHandler)(void); 
@property(nonatomic, strong) NSMutableDictionary *processAssertions;
@property(nonatomic, strong) NSMutableSet *pendingConnections;
@property(nonatomic, strong) NSMutableDictionary *activeConnections;
@property(nonatomic, strong) NSMutableDictionary *globalIncomingMessageHandlers;
@property(nonatomic, strong) NSMutableDictionary *incomingMessageHandlers;
@property(nonatomic, strong) NSMutableDictionary *outgoingMessageQueue;

// process checking methods
+ (BOOL)isServer;
+ (BOOL)isApp;

// retrieve the shared instance
+ (instancetype)sharedInstance;

// these two methods will be called automatically when needed
+ (void)activate;
+ (void)deactivate;

/*** Asynchronous message delivery ***/

// Server* -----> App
+ (BOOL)sendMessageToAppWithIdentifier:(NSString *)identifier messageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)handler;
+ (void)broadcastMessageToAppsWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)handler;

// App* -----> Server
+ (BOOL)sendMessageToServerWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)handler;

/*** Register incoming message handler ***/

// App -----> Server*
+ (void)registerIncomingMessageFromAppHandlerForMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler;
+ (void)unregisterIncomingMessageFromAppHandlerForMessageName:(NSString *)messageName;

+ (void)unregisterIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier andMessageName:(NSString *)messageName;
+ (void)registerIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier andMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler;

// Server -----> App*
+ (void)registerIncomingMessageFromServerHandlerForMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler;
+ (void)unregisterIncomingMessageFromServerHandlerForMessageName:(NSString *)messageName;

/*** For testing purpose ***/

+ (void)registerTestIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier;
+ (void)registerTestIncomingMessageHandlerForServer;
+ (void)sendAsynchronousTestMessageToAppWithIdentifier:(NSString *)identifier;
+ (void)sendAsynchronousTestMessageToServer;

// manage connections
- (OBJCIPCConnection *)activeConnectionWithAppWithIdentifier:(NSString *)identifier;
- (void)addPendingConnection:(OBJCIPCConnection *)connection;
- (void)notifyConnectionBecomesActive:(OBJCIPCConnection *)connection;
- (void)notifyConnectionIsClosed:(OBJCIPCConnection *)connection;
- (void)removeConnection:(OBJCIPCConnection *)connection;

// queue up the outgoing message
- (void)queueOutgoingMessage:(OBJCIPCMessage *)message forAppWithIdentifier:(NSString *)identifier;

// private methods to setup socket server and connection
- (NSUInteger)_createSocketServer;
- (void)_createPairWithAppSocket:(CFSocketNativeHandle)handle;
- (void)_connectToServer;

@end
