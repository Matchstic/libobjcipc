#define LOG_MESSAGE_BODY 0
#define DEBUG 1

#ifdef DEBUG
	#define IPCLOG(x,...) NSLog(@"*** libobjcipc: %@",[NSString stringWithFormat:(x), ##__VA_ARGS__])
#else
	// Replace with call to [NSString stringWithFormat:] so that any variables passed aren't marked as unused.
	#define IPCLOG(x,...) [NSString stringWithFormat:(x), ##__VA_ARGS__]
#endif

#define SETTINGS_NOTIFICATION CFSTR("com.matchstic.libwidgetinfo/update")
#define SERVER_ID @"com.matchstic.libwidgetinfo"

#import <Foundation/Foundation.h>

@class OBJCIPC, OBJCIPCConnection, OBJCIPCMessage;

typedef void(^OBJCIPCIncomingMessageHandler)(NSDictionary *data, void (^callback)(NSDictionary* response)); // return NSDictionary or nil to reply
typedef void(^OBJCIPCReplyHandler)(NSDictionary *);

typedef struct {
	
	char magicNumber[3];
	BOOL replyFlag;
	char messageIdentifier[5];
	char messageName[256];
	int contentLength;
	
} OBJCIPCMessageHeader;
