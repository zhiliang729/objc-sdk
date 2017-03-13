//
//  LCIMConversationCacheStore.m
//  AVOS
//
//  Created by Tang Tianyong on 8/29/15.
//  Copyright (c) 2015 LeanCloud Inc. All rights reserved.
//

#import "LCIMConversationCacheStore.h"
#import "LCIMConversationCacheStoreSQL.h"
#import "LCIMMessageCacheStoreSQL.h"
#import "AVIMConversation.h"
#import "AVIMConversation_Internal.h"
#import "LCDatabaseMigrator.h"

#define LCIM_CONVERSATION_MAX_CACHE_AGE 60 * 60 * 24

@implementation LCIMConversationCacheStore

- (NSArray *)insertionRecordForConversation:(AVIMConversation *)conversation expireAt:(NSTimeInterval)expireAt {
    return @[
        conversation.conversationId,
        conversation.name ?: [NSNull null],
        conversation.creator ?: [NSNull null],
        [NSNumber numberWithInteger:conversation.transient],
        conversation.members ? [conversation.members componentsJoinedByString:@","] : [NSNull null],
        conversation.attributes ? [NSKeyedArchiver archivedDataWithRootObject:conversation.attributes] : [NSNull null],
        [NSNumber numberWithDouble:[conversation.createAt timeIntervalSince1970]],
        [NSNumber numberWithDouble:[conversation.updateAt timeIntervalSince1970]],
        [NSNumber numberWithDouble:[conversation.lastMessageAt timeIntervalSince1970]],
        [NSNumber numberWithDouble:[conversation.lastDeliveredAt timeIntervalSince1970]],
        [NSNumber numberWithDouble:[conversation.lastReadAt timeIntervalSince1970]],
        conversation.lastMessage ? [NSKeyedArchiver archivedDataWithRootObject:conversation.lastMessage] : [NSNull null],
        [NSNumber numberWithInteger:conversation.muted],
        [NSNumber numberWithDouble:expireAt]
    ];
}

- (void)insertConversations:(NSArray *)conversations {
    [self insertConversations:conversations maxAge:LCIM_CONVERSATION_MAX_CACHE_AGE];
}

- (void)insertConversations:(NSArray *)conversations maxAge:(NSTimeInterval)maxAge {
    NSTimeInterval expireAt = [[NSDate date] timeIntervalSince1970] + maxAge;
    for (AVIMConversation *conversation in conversations) {
        if (!conversation.conversationId) continue;
        BOOL noMembers = (!conversation.members || conversation.members.count == 0);
        if (noMembers) {
            AVIMConversation *conversationInCache = [self conversationForId:conversation.conversationId];
            if (noMembers) {
                conversation.members = conversationInCache.members;
            }
        }
        NSArray *insertionRecord = [self insertionRecordForConversation:conversation expireAt:expireAt];
        LCIM_OPEN_DATABASE(db, ({
            [db executeUpdate:LCIM_SQL_INSERT_CONVERSATION withArgumentsInArray:insertionRecord];
        }));
    }
}

- (void)deleteConversation:(AVIMConversation *)conversation {
    [self deleteConversationForId:conversation.conversationId];
}

- (void)deleteConversationForId:(NSString *)conversationId {
    if (!conversationId) return;

    LCIM_OPEN_DATABASE(db, ({
        NSArray *args = @[conversationId];
        [db executeUpdate:LCIM_SQL_DELETE_CONVERSATION withArgumentsInArray:args];
    }));
}

- (void)deleteAllMessageOfConversationForId:(NSString *)conversationId {
    if (!conversationId) return;

    LCIM_OPEN_DATABASE(db, ({
        NSArray *args = @[conversationId];
        [db executeUpdate:LCIM_SQL_DELETE_ALL_MESSAGES_OF_CONVERSATION withArgumentsInArray:args];
    }));
}

- (void)deleteConversationAndItsMessagesForId:(NSString *)conversationId {
    [self deleteConversationForId:conversationId];
    [self deleteAllMessageOfConversationForId:conversationId];
}

- (void)updateConversationForLastMessageAt:(NSDate *)lastMessageAt conversationId:(NSString *)conversationId {
    [self setValue:lastMessageAt forField:LCIM_FIELD_LAST_MESSAGE_AT conversationId:conversationId];
}

- (void)setValue:(id)value forField:(NSString *)field conversationId:(NSString *)conversationId {
    if (!field || !conversationId)
        return;

    if (!value)
        value = [NSNull null];

    field = [field stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *statement = [NSString stringWithFormat:LCIM_SQL_UPDATE_CONVERSATION_FIELD_FORMAT, field];

    LCIM_OPEN_DATABASE(db, ({
        NSArray *args = @[value, conversationId];
        [db executeUpdate:statement withArgumentsInArray:args];
    }));
}

- (id)valueForField:(NSString *)field conversationId:(NSString *)conversationId {
    if (!field || !conversationId)
        return nil;

    __block id value = nil;

    LCIM_OPEN_DATABASE(db, ({
        NSArray *args = @[conversationId];
        LCResultSet *result = [db executeQuery:LCIM_SQL_SELECT_CONVERSATION withArgumentsInArray:args];

        if ([result next])
            value = [result objectForColumnName:field];

        [result close];
    }));

    return value;
}

- (AVIMConversation *)conversationForId:(NSString *)conversationId timestamp:(NSTimeInterval)timestamp {
    __block AVIMConversation *conversation = nil;

    LCIM_OPEN_DATABASE(db, ({
        conversation = [self conversationForId:conversationId database:db timestamp:timestamp];
    }));

    return conversation;
}

- (AVIMConversation *)conversationForId:(NSString *)conversationId database:(LCDatabase *)database timestamp:(NSTimeInterval)timestamp {
    if (!conversationId) return nil;

    AVIMConversation *conversation = nil;

    NSArray *args = @[conversationId];
    LCResultSet *result = [database executeQuery:LCIM_SQL_SELECT_CONVERSATION withArgumentsInArray:args];

    if ([result next]) {
        NSTimeInterval expireAt = [result doubleForColumn:LCIM_FIELD_EXPIRE_AT];

        if (expireAt <= timestamp) {
            [database executeUpdate:LCIM_SQL_DELETE_CONVERSATION withArgumentsInArray:@[conversationId]];
        } else {
            conversation = [self conversationWithResult:result];
        }
    }

    [result close];

    return conversation;
}

- (AVIMConversation *)conversationForId:(NSString *)conversationId {
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];

    return [self conversationForId:conversationId timestamp:timestamp];
}

- (NSDate *)dateFromTimeInterval:(NSTimeInterval)timeInterval {
    return timeInterval ? [NSDate dateWithTimeIntervalSince1970:timeInterval] : nil;
}

- (AVIMConversation *)conversationWithResult:(LCResultSet *)result {
    AVIMConversation *conversation = [[AVIMConversation alloc] init];

    conversation.conversationId = [result stringForColumn:LCIM_FIELD_CONVERSATION_ID];
    conversation.name           = [result stringForColumn:LCIM_FIELD_NAME];
    conversation.creator        = [result stringForColumn:LCIM_FIELD_CREATOR];
    conversation.transient      = [result boolForColumn:LCIM_FIELD_TRANSIENT];
    conversation.members        = [[result stringForColumn:LCIM_FIELD_MEMBERS] componentsSeparatedByString:@","];
    conversation.attributes     = ({
        NSData *data = [result dataForColumn:LCIM_FIELD_ATTRIBUTES];
        data ? [NSKeyedUnarchiver unarchiveObjectWithData:data] : nil;
    });
    conversation.createAt       = [self dateFromTimeInterval:[result doubleForColumn:LCIM_FIELD_CREATE_AT]];
    conversation.updateAt       = [self dateFromTimeInterval:[result doubleForColumn:LCIM_FIELD_UPDATE_AT]];
    conversation.lastMessageAt  = [self dateFromTimeInterval:[result doubleForColumn:LCIM_FIELD_LAST_MESSAGE_AT]];
    conversation.lastDeliveredAt = [self dateFromTimeInterval:[result doubleForColumn:LCIM_FIELD_LAST_DELIVERED_AT]];
    conversation.lastReadAt     = [self dateFromTimeInterval:[result doubleForColumn:LCIM_FIELD_LAST_READ_AT]];
    conversation.lastMessage    = ({
        NSData *data = [result dataForColumn:LCIM_FIELD_LAST_MESSAGE];
        data ? [NSKeyedUnarchiver unarchiveObjectWithData:data] : nil;
    });
    conversation.muted          = [result boolForColumn:LCIM_FIELD_MUTED];
    return conversation;
}

- (NSArray *)conversationsForIds:(NSArray *)conversationIds {
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];

    __block BOOL isOK = YES;
    NSMutableArray *conversations = [NSMutableArray array];

    LCIM_OPEN_DATABASE(db, ({
        for (NSString *conversationId in conversationIds) {
            AVIMConversation *conversation = [self conversationForId:conversationId database:db timestamp:timestamp];

            if (conversation) {
                [conversations addObject:conversation];
            } else {
                isOK = NO;
                return;
            }
        }
    }));

    return isOK ? conversations : @[];
}

- (NSArray *)allAliveConversations {
    NSMutableArray *conversations = [NSMutableArray array];

    LCIM_OPEN_DATABASE(db, ({
        NSArray *args = @[[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]]];
        LCResultSet *result = [db executeQuery:LCIM_SQL_SELECT_ALIVE_CONVERSATIONS withArgumentsInArray:args];

        while ([result next]) {
            [conversations addObject:[self conversationWithResult:result]];
        }

        [result close];
    }));

    return conversations;
}

- (NSArray *)allExpiredConversations {
    NSMutableArray *conversations = [NSMutableArray array];

    LCIM_OPEN_DATABASE(db, ({
        NSArray *args = @[[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]]];
        LCResultSet *result = [db executeQuery:LCIM_SQL_SELECT_EXPIRED_CONVERSATIONS withArgumentsInArray:args];

        while ([result next]) {
            [conversations addObject:[self conversationWithResult:result]];
        }

        [result close];
    }));

    return conversations;
}

- (void)cleanAllExpiredConversations {
    NSArray *conversations = [self allExpiredConversations];

    for (AVIMConversation *conversation in conversations) {
        [self deleteConversation:conversation];
    }
}

@end
