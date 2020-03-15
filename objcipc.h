//
//  libobjcipc
//  include.h
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "header.h"
#import "IPC.h"
#import "Connection.h"
#import "Message.h"

typedef enum
{
    NSNotificationSuspensionBehaviorDrop = 1,
    NSNotificationSuspensionBehaviorCoalesce = 2,
    NSNotificationSuspensionBehaviorHold = 3,
    NSNotificationSuspensionBehaviorDeliverImmediately = 4
} NSNotificationSuspensionBehavior;

@interface NSDistributedNotificationCenter : NSNotificationCenter

+ (instancetype)defaultCenter;
- (void)addObserver:(id)notificationObserver selector:(SEL)notificationSelector name:(NSString *)notificationName object:(NSString *)notificationSender suspensionBehavior:(NSNotificationSuspensionBehavior)suspendedDeliveryBehavior;
- (void)removeObserver:(id)notificationObserver name:(NSString *)notificationName object:(NSString *)notificationSender;
- (void)postNotificationName:(NSString *)notificationName object:(NSString *)notificationSender userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately;

@end
