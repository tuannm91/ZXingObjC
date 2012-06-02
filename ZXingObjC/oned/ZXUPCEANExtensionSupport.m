/*
 * Copyright 2012 ZXing authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "ZXBitArray.h"
#import "ZXErrors.h"
#import "ZXResult.h"
#import "ZXResultPoint.h"
#import "ZXUPCEANExtensionSupport.h"
#import "ZXUPCEANReader.h"

const int EXTENSION_START_PATTERN_LEN = 3;
const int EXTENSION_START_PATTERN[EXTENSION_START_PATTERN_LEN] = {1,1,2};
const int CHECK_DIGIT_ENCODINGS[10] = {
  0x18, 0x14, 0x12, 0x11, 0x0C, 0x06, 0x03, 0x0A, 0x09, 0x05
};

@interface ZXUPCEANExtensionSupport ()

- (int)determineCheckDigit:(int)lgPatternFound;
- (int)extensionChecksum:(NSString *)s;
- (NSMutableDictionary *)parseExtensionString:(NSString *)raw;
- (NSNumber *)parseExtension2String:(NSString *)raw;
- (NSString *)parseExtension5String:(NSString *)raw;

@end

@implementation ZXUPCEANExtensionSupport

- (ZXResult *)decodeRow:(int)rowNumber row:(ZXBitArray *)row rowOffset:(int)rowOffset error:(NSError **)error {
  NSRange extensionStartRange = [ZXUPCEANReader findGuardPattern:row rowOffset:rowOffset whiteFirst:NO pattern:(int*)EXTENSION_START_PATTERN patternLen:EXTENSION_START_PATTERN_LEN error:error];
  if (extensionStartRange.location == NSNotFound) {
    return nil;
  }

  NSMutableString * result = [NSMutableString string];
  int end = [self decodeMiddle:row startRange:extensionStartRange result:result error:error];
  if (end == -1) {
    return nil;
  }

  NSMutableDictionary * extensionData = [self parseExtensionString:result];

  ZXResult * extensionResult = [[[ZXResult alloc] initWithText:result
                                                      rawBytes:NULL
                                                        length:0
                                                  resultPoints:[NSArray arrayWithObjects:
                                                                [[[ZXResultPoint alloc] initWithX:(extensionStartRange.location + NSMaxRange(extensionStartRange)) / 2.0f y:(float)rowNumber] autorelease],
                                                                [[[ZXResultPoint alloc] initWithX:(float)end y:(float)rowNumber] autorelease], nil]
                                                        format:kBarcodeFormatUPCEANExtension] autorelease];
  if (extensionData != nil) {
    [extensionResult putAllMetadata:extensionData];
  }
  return extensionResult;
}

- (int)decodeMiddle:(ZXBitArray *)row startRange:(NSRange)startRange result:(NSMutableString *)result error:(NSError**)error {
  const int countersLen = 4;
  int counters[countersLen] = {0, 0, 0, 0};
  int end = [row size];
  int rowOffset = NSMaxRange(startRange);

  int lgPatternFound = 0;

  for (int x = 0; x < 5 && rowOffset < end; x++) {
    int bestMatch = [ZXUPCEANReader decodeDigit:row counters:counters countersLen:countersLen rowOffset:rowOffset patternType:UPC_EAN_PATTERNS_L_AND_G_PATTERNS error:error];
    if (bestMatch == -1) {
      return -1;
    }
    [result appendFormat:@"%C", (unichar)('0' + bestMatch % 10)];
    for (int i = 0; i < countersLen; i++) {
      rowOffset += counters[i];
    }
    if (bestMatch >= 10) {
      lgPatternFound |= 1 << (4 - x);
    }
    if (x != 4) {
      while (rowOffset < end && ![row get:rowOffset]) {
        rowOffset++;
      }
      while (rowOffset < end && [row get:rowOffset]) {
        rowOffset++;
      }
    }
  }

  if (result.length != 5) {
    if (error) *error = NotFoundErrorInstance();
    return -1;
  }

  int checkDigit = [self determineCheckDigit:lgPatternFound];
  if (checkDigit == -1) {
    if (error) *error = NotFoundErrorInstance();
    return -1;
  } else if ([self extensionChecksum:result] != checkDigit) {
    if (error) *error = NotFoundErrorInstance();
    return -1;
  }

  return rowOffset;
}

- (int)extensionChecksum:(NSString *)s {
  int length = [s length];
  int sum = 0;
  for (int i = length - 2; i >= 0; i -= 2) {
    sum += (int)[s characterAtIndex:i] - (int)'0';
  }
  sum *= 3;
  for (int i = length - 1; i >= 0; i -= 2) {
    sum += (int)[s characterAtIndex:i] - (int)'0';
  }
  sum *= 3;
  return sum % 10;
}

- (int)determineCheckDigit:(int)lgPatternFound {
  for (int d = 0; d < 10; d++) {
    if (lgPatternFound == CHECK_DIGIT_ENCODINGS[d]) {
      return d;
    }
  }
  return -1;
}

- (NSMutableDictionary *)parseExtensionString:(NSString *)raw {
  ZXResultMetadataType type;
  id value;

  switch ([raw length]) {
  case 2:
    type = kResultMetadataTypeIssueNumber;
    value = [self parseExtension2String:raw];
    break;
  case 5:
    type = kResultMetadataTypeSuggestedPrice;
    value = [self parseExtension5String:raw];
    break;
  default:
    return nil;
  }
  if (value == nil) {
    return nil;
  }
  NSMutableDictionary * result = [NSMutableDictionary dictionaryWithCapacity:1];
  [result setObject:value forKey:[NSNumber numberWithInt:type]];
  return result;
}

- (NSNumber *)parseExtension2String:(NSString *)raw {
  return [NSNumber numberWithInt:[raw intValue]];
}

- (NSString *)parseExtension5String:(NSString *)raw {
  NSString * currency;
  switch ([raw characterAtIndex:0]) {
  case '0':
    currency = @"£";
    break;
  case '5':
    currency = @"$";
    break;
  case '9':
    if ([@"90000" isEqualToString:raw]) {
      return nil;
    }
    if ([@"99991" isEqualToString:raw]) {
      return @"0.00";
    }
    if ([@"99990" isEqualToString:raw]) {
      return @"Used";
    }
    currency = @"";
    break;
  default:
    currency = @"";
    break;
  }
  int rawAmount = [[raw substringFromIndex:1] intValue];
  NSString * unitsString = [[NSNumber numberWithInt:rawAmount / 100] stringValue];
  int hundredths = rawAmount % 100;
  NSString * hundredthsString = hundredths < 10 ? 
  [NSString stringWithFormat:@"0%d", hundredths] : [[NSNumber numberWithInt:hundredths] stringValue];
  return [NSString stringWithFormat:@"%@%@.%@", currency, unitsString, hundredthsString];
}

@end
