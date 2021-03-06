// Copyright 2015-present 650 Industries. All rights reserved.

#import "ABI18_0_0EXSQLite.h"

#import "ABI18_0_0EXScope.h"
#import "ABI18_0_0EXFileSystem.h"

#import <sqlite3.h>

@interface ABI18_0_0EXSQLite ()

@property (nonatomic, copy) NSMutableDictionary *cachedDatabases;

@end

@implementation ABI18_0_0EXSQLite

@synthesize cachedDatabases;

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

ABI18_0_0RCT_EXPORT_MODULE(ExponentSQLite)

@synthesize bridge = _bridge;

- (void)setBridge:(ABI18_0_0RCTBridge *)bridge
{
  _bridge = bridge;
  cachedDatabases = [NSMutableDictionary dictionary];
}

- (NSValue *)openDatabase:(NSString *)dbName
{
  NSValue *cachedDB = [cachedDatabases objectForKey:dbName];
  if (cachedDB == nil) {
    [ABI18_0_0EXFileSystem ensureDirExistsWithPath:[self.bridge.experienceScope scopedPathWithPath:@"SQLite" withOptions:@{}]];
    NSString *path = [self.bridge.experienceScope scopedPathWithPath:[@"SQLite" stringByAppendingPathComponent:dbName]
                                                               withOptions:@{}];
    sqlite3 *db;
    if (sqlite3_open([path UTF8String], &db) != SQLITE_OK) {
      return nil;
    };
    cachedDB = [NSValue valueWithPointer:db];
    [cachedDatabases setObject:cachedDB forKey: dbName];
  }
  return cachedDB;
}

ABI18_0_0RCT_EXPORT_METHOD(exec:(NSString *)dbName
                  queries:(NSArray *)sqlQueries
                  readOnly:(BOOL)readOnly
                  resolver:(ABI18_0_0RCTPromiseResolveBlock)resolve
                  rejecter:(ABI18_0_0RCTPromiseRejectBlock)reject)
{
  @synchronized(self) {
    NSValue *databasePointer = [self openDatabase:dbName];
    if (!databasePointer) {
      reject(@"E_SQLITE_OPEN_DATABASE", @"Could not open database.", nil);
      return;
    }

    sqlite3 *db = [databasePointer pointerValue];
    NSMutableArray *sqlResults = [NSMutableArray arrayWithCapacity:sqlQueries.count];
    for (NSArray *sqlQueryObject in sqlQueries) {
      NSString *sql = [sqlQueryObject objectAtIndex:0];
      NSArray *sqlArgs = [sqlQueryObject objectAtIndex:1];
      [sqlResults addObject:[self executeSql:sql withSqlArgs:sqlArgs withDb:db withReadOnly:readOnly]];
    }
    resolve(sqlResults);
  }
}

- (id)getSqlValueForColumnType:(int)columnType withStatement:(sqlite3_stmt*)statement withIndex:(int)i
{
  switch (columnType) {
    case SQLITE_INTEGER:
      return @(sqlite3_column_int64(statement, i));
    case SQLITE_FLOAT:
      return @(sqlite3_column_double(statement, i));
    case SQLITE_BLOB:
    case SQLITE_TEXT:
      return [[NSString alloc] initWithBytes:(char *)sqlite3_column_text(statement, i)
                                      length:sqlite3_column_bytes(statement, i)
                                    encoding:NSUTF8StringEncoding];
  }
  return [NSNull null];
}

- (NSArray *)executeSql:(NSString*)sql withSqlArgs:(NSArray*)sqlArgs
                 withDb:(sqlite3*)db withReadOnly:(BOOL)readOnly
{
  NSString *error = nil;
  sqlite3_stmt *statement;
  NSMutableArray *resultRows = [NSMutableArray arrayWithCapacity:0];
  NSMutableArray *entry;
  long insertId = 0;
  int rowsAffected = 0;
  int i;

  // compile the statement, throw an error if necessary
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
    error = [ABI18_0_0EXSQLite convertSQLiteErrorToString:db];
    return @[error];
  }

  bool queryIsReadOnly = sqlite3_stmt_readonly(statement);
  if (readOnly && !queryIsReadOnly) {
    error = [NSString stringWithFormat:@"could not prepare %@", sql];
    return @[error];
  }

  // bind any arguments
  if (sqlArgs != nil) {
    for (i = 0; i < sqlArgs.count; i++) {
      [self bindStatement:statement withArg:[sqlArgs objectAtIndex:i] atIndex:(i + 1)];
    }
  }

  int previousRowsAffected = 0;
  if (!queryIsReadOnly) {
    // calculate the total changes in order to diff later
    previousRowsAffected = sqlite3_total_changes(db);
  }

  // iterate through sql results
  int columnCount = 0;
  NSMutableArray *columnNames = [NSMutableArray arrayWithCapacity:0];
  NSString *columnName;
  int columnType;
  BOOL fetchedColumns = NO;
  int result;
  NSObject *columnValue;
  BOOL hasMore = YES;
  while (hasMore) {
    result = sqlite3_step (statement);
    switch (result) {
      case SQLITE_ROW:
        if (!fetchedColumns) {
          // get all column names once at the beginning
          columnCount = sqlite3_column_count(statement);

          for (i = 0; i < columnCount; i++) {
            columnName = [NSString stringWithFormat:@"%s", sqlite3_column_name(statement, i)];
            [columnNames addObject:columnName];
          }
          fetchedColumns = YES;
        }
        entry = [NSMutableArray arrayWithCapacity:columnCount];
        for (i = 0; i < columnCount; i++) {
          columnType = sqlite3_column_type(statement, i);
          columnValue = [self getSqlValueForColumnType:columnType withStatement:statement withIndex: i];
          [entry addObject:columnValue];
        }
        [resultRows addObject:entry];
        break;
      case SQLITE_DONE:
        hasMore = NO;
        break;
      default:
        error = [ABI18_0_0EXSQLite convertSQLiteErrorToString:db];
        hasMore = NO;
        break;
    }
  }

  if (!queryIsReadOnly) {
    rowsAffected = (sqlite3_total_changes(db) - previousRowsAffected);
    if (rowsAffected > 0) {
      insertId = sqlite3_last_insert_rowid(db);
    }
  }

  sqlite3_finalize(statement);

  if (error) {
    return @[error];
  }
  return @[[NSNull null], @(insertId), @(rowsAffected), columnNames, resultRows];
}

- (void)bindStatement:(sqlite3_stmt *)statement withArg:(NSObject *)arg atIndex:(int)argIndex
{
  if ([arg isEqual:[NSNull null]]) {
    sqlite3_bind_null(statement, argIndex);
  } else if ([arg isKindOfClass:[NSNumber class]]) {
    sqlite3_bind_double(statement, argIndex, [((NSNumber *) arg) doubleValue]);
  } else { // NSString
    NSString *stringArg;

    if ([arg isKindOfClass:[NSString class]]) {
      stringArg = (NSString *)arg;
    } else {
      stringArg = [arg description]; // convert to text
    }

    NSData *data = [stringArg dataUsingEncoding:NSUTF8StringEncoding];
    sqlite3_bind_text(statement, argIndex, data.bytes, (int)data.length, SQLITE_TRANSIENT);
  }
}

- (void)dealloc
{
  for (NSString *key in cachedDatabases) {
    sqlite3_close([[cachedDatabases objectForKey:key] pointerValue]);
  }
}

+ (NSString *)convertSQLiteErrorToString:(struct sqlite3 *)db
{
  int code = sqlite3_errcode(db);
  NSString *message = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
  return [NSString stringWithFormat:@"Error code %i: %@", code, message];
}

@end
