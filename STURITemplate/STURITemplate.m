//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
//  Copyright (c) 2014 Scott Talbot.

#import "STURITemplate.h"


NSString * const STURITemplateErrorDomain = @"STURITemplate";


typedef id(^STURITArrayMapBlock)(id o);

static NSArray *STURITArrayByMappingArray(NSArray *array, STURITArrayMapBlock block) {
    NSUInteger const count = array.count;
    id values[count];
    memset(values, 0, sizeof(values));
    NSUInteger i = 0;
    for (id o in array) {
        id v = block(o);
        if (v) {
            values[i++] = v;
        }
    }
    return [[NSArray alloc] initWithObjects:values count:i];
}


static NSCharacterSet *STURITemplateScannerHexCharacterSet = nil;
static NSCharacterSet *STURITemplateScannerInvertedLiteralComponentCharacterSet = nil;
static NSCharacterSet *STURITemplateScannerOperatorCharacterSet = nil;
static NSCharacterSet *STURITemplateScannerInvertedVariableNameCharacterSet = nil;
static NSCharacterSet *STURITemplateScannerInvertedVariableNameMinusDotCharacterSet = nil;


__attribute__((constructor))
static void STURITemplateScannerInit(void) {
    STURITemplateScannerHexCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];

    {
        NSMutableCharacterSet *cs = [[[NSCharacterSet illegalCharacterSet] invertedSet] mutableCopy];
        [cs formIntersectionWithCharacterSet:[[NSCharacterSet controlCharacterSet] invertedSet]];
        [cs formIntersectionWithCharacterSet:[[NSCharacterSet characterSetWithCharactersInString:@" \"'%<>\\^`{|}"] invertedSet]];
        STURITemplateScannerInvertedLiteralComponentCharacterSet = cs.invertedSet;
    }

    STURITemplateScannerOperatorCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@"+#./;?&=,!@|"];

    {
        NSMutableCharacterSet *cs = [[NSMutableCharacterSet alloc] init];
        [cs addCharactersInString:@"abcdefghijklmnopqrstuvwxyz"];
        [cs addCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ"];
        [cs addCharactersInString:@"0123456789"];
        [cs addCharactersInString:@"_%"];
        STURITemplateScannerInvertedVariableNameMinusDotCharacterSet = cs.invertedSet;

        [cs addCharactersInString:@"."];
        STURITemplateScannerInvertedVariableNameCharacterSet = cs.invertedSet;
    }
}


@protocol STURITemplateComponent <NSObject>
@property (nonatomic,copy,readonly) NSArray *variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables;
- (NSString *)templateRepresentation;
@end
@interface STURITemplateLiteralComponent : NSObject<STURITemplateComponent>
- (id)initWithString:(NSString *)string;
@end
@interface STURITemplateVariableComponent : NSObject
- (id)initWithVariables:(NSArray *)variables __attribute__((objc_designated_initializer));
@end
@interface STURITemplateSimpleComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end
@interface STURITemplateReservedCharacterComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end
@interface STURITemplateFragmentComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end
@interface STURITemplatePathSegmentComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end
@interface STURITemplatePathExtensionComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end
@interface STURITemplateQueryComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end
@interface STURITemplateQueryContinuationComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end
@interface STURITemplatePathParameterComponent : STURITemplateVariableComponent<STURITemplateComponent>
@end


typedef NS_ENUM(NSInteger, STURITemplateEscapingStyle) {
    STURITemplateEscapingStyleU,
    STURITemplateEscapingStyleUR,
};
static NSString *STURITemplateStringByAddingPercentEscapes(NSString *string, STURITemplateEscapingStyle style) {
    CFStringRef legalURLCharactersToBeEscaped = nil;
    switch (style) {
        case STURITemplateEscapingStyleU:
            legalURLCharactersToBeEscaped = CFSTR("!#$&'()*+,/:;=?@[]%");
            break;
        case STURITemplateEscapingStyleUR:
            break;
    }
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)string, NULL, legalURLCharactersToBeEscaped, kCFStringEncodingUTF8);
}


@interface STURITemplateComponentVariable : NSObject
- (id)initWithName:(NSString *)name;
@property (nonatomic,copy,readonly) NSString *name;
- (NSString *)stringWithValue:(id)value encodingStyle:(STURITemplateEscapingStyle)encodingStyle;
- (NSString *)templateRepresentation;
@end

@interface STURITemplateComponentTruncatedVariable : STURITemplateComponentVariable
- (id)initWithName:(NSString *)name length:(NSUInteger)length;
- (NSString *)templateRepresentation;
@end

@interface STURITemplateComponentExplodedVariable : STURITemplateComponentVariable
- (NSString *)templateRepresentation;
@end


@interface STURITemplateScanner : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithString:(NSString *)string __attribute__((objc_designated_initializer));
- (BOOL)scanString:(NSString *)string intoString:(NSString * __autoreleasing *)result;
- (BOOL)scanCharactersFromSet:(NSCharacterSet *)set intoString:(NSString **)result;
- (BOOL)scanUpToString:(NSString *)string intoString:(NSString * __autoreleasing *)result;
- (BOOL)scanUpToCharactersFromSet:(NSCharacterSet *)set intoString:(NSString * __autoreleasing *)result;
@property (nonatomic,assign,getter=isAtEnd,readonly) BOOL atEnd;
- (BOOL)sturit_scanTemplateComponent:(id<STURITemplateComponent> __autoreleasing *)component;
@end
@implementation STURITemplateScanner {
@private
    NSScanner *_scanner;
}
- (instancetype)initWithString:(NSString *)string {
    NSScanner * const scanner = [[NSScanner alloc] initWithString:string];
    if (!scanner) {
        return nil;
    }
    scanner.charactersToBeSkipped = nil;
    if ((self = [super init])) {
        _scanner = scanner;
    }
    return self;
}
- (BOOL)scanString:(NSString *)string intoString:(NSString * __autoreleasing *)result {
    return [_scanner scanString:string intoString:result];
}
- (BOOL)scanCharactersFromSet:(NSCharacterSet *)set intoString:(NSString **)result {
    return [_scanner scanCharactersFromSet:set intoString:result];
}
- (BOOL)scanUpToString:(NSString *)string intoString:(NSString * __autoreleasing *)result {
    return [_scanner scanUpToString:string intoString:result];
}
- (BOOL)scanUpToCharactersFromSet:(NSCharacterSet *)set intoString:(NSString * __autoreleasing *)result {
    return [_scanner scanUpToCharactersFromSet:set intoString:result];
}
- (BOOL)isAtEnd {
    return [_scanner isAtEnd];
}
- (NSString *)sturit_peekStringUpToLength:(NSUInteger)length {
    NSString * const string = _scanner.string;
    NSUInteger const scanLocation = _scanner.scanLocation;

    NSRange range = (NSRange){
        .location = scanLocation,
    };
    range.length = MIN(length, string.length - range.location);
    return [string substringWithRange:range];
}
- (BOOL)sturit_scanPercentEncoded:(NSString * __autoreleasing *)result {
    NSUInteger const scanLocation = _scanner.scanLocation;

    NSMutableString * const string = @"%".mutableCopy;

    if (![_scanner scanString:@"%" intoString:NULL]) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    NSString * const candidateString = [self sturit_peekStringUpToLength:2];
    if (candidateString.length != 2) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }
    unichar candidateCharacters[2] = { 0 };
    [candidateString getCharacters:candidateCharacters range:(NSRange){ .length = 2 }];

    if (![STURITemplateScannerHexCharacterSet characterIsMember:candidateCharacters[0]]) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }
    if (![STURITemplateScannerHexCharacterSet characterIsMember:candidateCharacters[1]]) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    _scanner.scanLocation += candidateString.length;
    [string appendString:candidateString];

    if (result) {
        *result = string.copy;
    }
    return YES;
}
- (BOOL)sturit_scanLiteralComponent:(id<STURITemplateComponent> __autoreleasing *)result {
    NSUInteger const scanLocation = _scanner.scanLocation;

    NSMutableString * const string = [NSMutableString string];
    while (![_scanner isAtEnd]) {
        BOOL didSomething = NO;
        NSString *scratch = nil;

        if ([_scanner scanUpToCharactersFromSet:STURITemplateScannerInvertedLiteralComponentCharacterSet intoString:&scratch]) {
            [string appendString:scratch];
            didSomething = YES;
        } else if ([self sturit_scanPercentEncoded:&scratch]) {
            [string appendString:scratch];
            didSomething = YES;
        }

        if (!didSomething) {
            break;
        }
    }

    if (!string.length) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    STURITemplateLiteralComponent * const literalComponent = [[STURITemplateLiteralComponent alloc] initWithString:string];
    if (!literalComponent) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    if (result) {
        *result = literalComponent;
    }
    return YES;
}
- (BOOL)sturit_scanVariableName:(NSString * __autoreleasing *)result {
    NSUInteger const scanLocation = _scanner.scanLocation;

    NSMutableString * const string = [[NSMutableString alloc] init];

    {
        NSString *scratch = nil;
        if ([_scanner scanUpToCharactersFromSet:STURITemplateScannerInvertedVariableNameMinusDotCharacterSet intoString:&scratch]) {
            [string appendString:scratch];
        }
    }
    if (string.length == 0) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    {
        NSString *scratch = nil;
        if ([_scanner scanUpToCharactersFromSet:STURITemplateScannerInvertedVariableNameCharacterSet intoString:&scratch]) {
            [string appendString:scratch];
        }
    }

    if (result) {
        *result = string.copy;
    }
    return YES;
}
- (BOOL)sturit_scanVariableSpecification:(STURITemplateComponentVariable * __autoreleasing *)result {
    NSUInteger const scanLocation = _scanner.scanLocation;

    NSString *name = nil;
    if (![self sturit_scanVariableName:&name]) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    long long prefixLength = 0;
    if ([_scanner scanString:@":" intoString:NULL]) {
        if (![_scanner scanLongLong:&prefixLength]) {
            [_scanner setScanLocation:scanLocation];
            return NO;
        }
        if (prefixLength < 0 || prefixLength >= 10000) {
            [_scanner setScanLocation:scanLocation];
            return NO;
        }
        STURITemplateComponentVariable * const variable = [[STURITemplateComponentTruncatedVariable alloc] initWithName:name length:(NSUInteger)prefixLength];
        if (result) {
            *result = variable;
        }
        return YES;
    }
    if ([_scanner scanString:@"*" intoString:NULL]) {
        STURITemplateComponentVariable * const variable = [[STURITemplateComponentExplodedVariable alloc] initWithName:name];
        if (result) {
            *result = variable;
        }
        return YES;
    }

    STURITemplateComponentVariable * const variable = [[STURITemplateComponentVariable alloc] initWithName:name];
    if (result) {
        *result = variable;
    }

    return YES;
}
- (BOOL)sturit_scanVariableComponent:(id<STURITemplateComponent> __autoreleasing *)result {
    NSUInteger const scanLocation = _scanner.scanLocation;

    if (![_scanner scanString:@"{" intoString:NULL]) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    NSString *operator = nil;
    {
        NSString * const candidateOperator = [self sturit_peekStringUpToLength:1];
        if (candidateOperator.length == 1 && [STURITemplateScannerOperatorCharacterSet characterIsMember:[candidateOperator characterAtIndex:0]]) {
            _scanner.scanLocation += 1;
            operator = candidateOperator;
        }
    }

    NSMutableArray * const variables = [[NSMutableArray alloc] init];
    while (1) {
        STURITemplateComponentVariable *variable = nil;
        if (![self sturit_scanVariableSpecification:&variable]) {
            [_scanner setScanLocation:scanLocation];
            return NO;
        }
        [variables addObject:variable];
        if (![_scanner scanString:@"," intoString:NULL]) {
            break;
        }
    }

    if (![_scanner scanString:@"}" intoString:NULL]) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    id<STURITemplateComponent> component = nil;
    if (operator.length > 0) {
        switch ([operator characterAtIndex:0]) {
            case '+':
                component = [[STURITemplateReservedCharacterComponent alloc] initWithVariables:variables];
                break;
            case '#':
                component = [[STURITemplateFragmentComponent alloc] initWithVariables:variables];
                break;
            case '.':
                component = [[STURITemplatePathExtensionComponent alloc] initWithVariables:variables];
                break;
            case '/':
                component = [[STURITemplatePathSegmentComponent alloc] initWithVariables:variables];
                break;
            case ';':
                component = [[STURITemplatePathParameterComponent alloc] initWithVariables:variables];
                break;
            case '?':
                component = [[STURITemplateQueryComponent alloc] initWithVariables:variables];
                break;
            case '&':
                component = [[STURITemplateQueryContinuationComponent alloc] initWithVariables:variables];
                break;
        }
        if (!component) {
            [_scanner setScanLocation:scanLocation];
            return NO;
        }
    }

    if (!component) {
        component = [[STURITemplateSimpleComponent alloc] initWithVariables:variables];
    }

    if (!component) {
        [_scanner setScanLocation:scanLocation];
        return NO;
    }

    if (result) {
        *result = component;
    }
    return YES;
}
- (BOOL)sturit_scanTemplateComponent:(id<STURITemplateComponent> __autoreleasing *)result {
    NSUInteger const scanLocation = _scanner.scanLocation;

    if ([self sturit_scanVariableComponent:result]) {
        return YES;
    }

    if ([self sturit_scanLiteralComponent:result]) {
        return YES;
    }

    [_scanner setScanLocation:scanLocation];
    return NO;
}
@end


@implementation STURITemplateLiteralComponent {
@private
    NSString *_string;
}
- (id)init {
    return [self initWithString:nil];
}
- (id)initWithString:(NSString *)string {
    if ((self = [super init])) {
        _string = string.copy;
    }
    return self;
}
- (NSArray *)variableNames {
    return @[];
}
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return _string;
}
- (NSString *)templateRepresentation {
    return _string;
}
@end


typedef NS_ENUM(NSInteger, STURITemplateVariableComponentPairStyle) {
    STURITemplateVariableComponentPairStyleNone,
    STURITemplateVariableComponentPairStyleElidedEquals,
    STURITemplateVariableComponentPairStyleTrailingEquals,
};

@implementation STURITemplateVariableComponent {
@protected
    NSArray *_variables;
    NSArray *_variableNames;
}
- (id)init {
    return [self initWithVariables:nil];
}
- (id)initWithVariables:(NSArray *)variables {
    if ((self = [super init])) {
        _variables = variables;
        _variableNames = [_variables valueForKey:@"name"];
    }
    return self;
}
- (NSArray *)variableNames {
    return _variableNames;
}
- (NSString *)stringWithVariables:(NSDictionary *)variables prefix:(NSString *)prefix separator:(NSString *)separator asPair:(STURITemplateVariableComponentPairStyle)asPair encodingStyle:(STURITemplateEscapingStyle)encodingStyle {
    NSMutableArray * const values = [[NSMutableArray alloc] initWithCapacity:_variables.count];
    for (STURITemplateComponentVariable *variable in _variables) {
        id const value = variables[variable.name];
        if (value) {
            NSString * const string = [variable stringWithValue:value encodingStyle:encodingStyle];
            if (!string) {
                return nil;
            }
            NSMutableString *value = [NSMutableString string];
            switch (asPair) {
                case STURITemplateVariableComponentPairStyleNone: {
                    if (string.length) {
                        [value appendString:string];
                    }
                } break;
                case STURITemplateVariableComponentPairStyleElidedEquals: {
                    [value appendString:variable.name];
                    if (string.length) {
                        [value appendFormat:@"=%@", string];
                    }
                } break;
                case STURITemplateVariableComponentPairStyleTrailingEquals: {
                    [value appendFormat:@"%@=", variable.name];
                    if (string.length) {
                        [value appendString:string];
                    }
                } break;
            }
            [values addObject:value];
        }
    }
    NSString *string = [values componentsJoinedByString:separator];
    if (string.length) {
        string = [(prefix ?: @"") stringByAppendingString:string];
    }
    return string;
}
- (NSString *)templateRepresentation {
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}
- (NSString *)templateRepresentationWithPrefix:(NSString *)prefix {
    NSString * const variablesTemplateRepresentation = [[_variables valueForKey:@"templateRepresentation"] componentsJoinedByString:@","];
    return [NSString stringWithFormat:@"{%@%@}", prefix, variablesTemplateRepresentation];
}
@end

@implementation STURITemplateSimpleComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@"" separator:@"," asPair:STURITemplateVariableComponentPairStyleNone encodingStyle:STURITemplateEscapingStyleU];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@""];
}
@end

@implementation STURITemplateReservedCharacterComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@"" separator:@"," asPair:STURITemplateVariableComponentPairStyleNone encodingStyle:STURITemplateEscapingStyleUR];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@"+"];
}
@end

@implementation STURITemplateFragmentComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@"#" separator:@"," asPair:STURITemplateVariableComponentPairStyleNone encodingStyle:STURITemplateEscapingStyleUR];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@"#"];
}
@end

@implementation STURITemplatePathSegmentComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@"/" separator:@"/" asPair:STURITemplateVariableComponentPairStyleNone encodingStyle:STURITemplateEscapingStyleU];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@"/"];
}
@end

@implementation STURITemplatePathExtensionComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@"." separator:@"." asPair:STURITemplateVariableComponentPairStyleNone encodingStyle:STURITemplateEscapingStyleU];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@"."];
}
@end

@implementation STURITemplateQueryComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@"?" separator:@"&" asPair:STURITemplateVariableComponentPairStyleTrailingEquals encodingStyle:STURITemplateEscapingStyleU];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@"?"];
}
@end

@implementation STURITemplateQueryContinuationComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@"&" separator:@"&" asPair:STURITemplateVariableComponentPairStyleTrailingEquals encodingStyle:STURITemplateEscapingStyleU];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@"&"];
}
@end

@implementation STURITemplatePathParameterComponent
@dynamic variableNames;
- (NSString *)stringWithVariables:(NSDictionary *)variables {
    return [super stringWithVariables:variables prefix:@";" separator:@";" asPair:STURITemplateVariableComponentPairStyleElidedEquals encodingStyle:STURITemplateEscapingStyleU];
}
- (NSString *)templateRepresentation {
    return [super templateRepresentationWithPrefix:@";"];
}
@end


@implementation STURITemplateComponentVariable {
@private
}
- (id)init {
    return [self initWithName:nil];
}
- (id)initWithName:(NSString *)name {
    if ((self = [super init])) {
        _name = name.copy;
    }
    return self;
}
- (NSString *)stringWithValue:(id)value encodingStyle:(STURITemplateEscapingStyle)encodingStyle {
    if (!value) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return STURITemplateStringByAddingPercentEscapes(value, encodingStyle);
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return ((NSNumber *)value).stringValue;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        return [STURITArrayByMappingArray(value, ^(id o) {
            return [self stringWithValue:o encodingStyle:encodingStyle];
        }) componentsJoinedByString:@","];
    }
    return nil;
}
- (NSString *)templateRepresentation {
    return _name;
}
@end

@implementation STURITemplateComponentTruncatedVariable {
@private
    NSUInteger _length;
}
- (id)initWithName:(NSString *)name length:(NSUInteger)length {
    if ((self = [super initWithName:name])) {
        _length = length;
    }
    return self;
}
- (NSString *)stringWithValue:(id)value preserveCharacters:(BOOL)preserveCharacters {
    if (!value) {
        return nil;
    }
    NSString *string = nil;
    if ([value isKindOfClass:[NSString class]]) {
        string = value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        string = ((NSNumber *)value).stringValue;
    }
    if (!string) {
        return nil;
    }
    return STURITemplateStringByAddingPercentEscapes([string substringToIndex:MIN(_length, string.length)], preserveCharacters ? STURITemplateEscapingStyleUR : STURITemplateEscapingStyleU);
}
- (NSString *)templateRepresentation {
    return [NSString stringWithFormat:@"%@:%lu", self.name, (unsigned long)_length];
}
@end

@implementation STURITemplateComponentExplodedVariable
- (NSString *)stringWithValue:(id)value preserveCharacters:(BOOL)preserveCharacters {
    NSAssert(0, @"unimplemented");
    return nil;
}
- (NSString *)templateRepresentation {
    return nil;
}
@end


@implementation STURITemplate {
@private
    NSArray *_components;
}
- (id)init {
    return [self initWithString:nil error:NULL];
}
- (id)initWithString:(NSString *)string {
    return [self initWithString:string error:NULL];
}
- (id)initWithString:(NSString *)string error:(NSError *__autoreleasing *)error {
    STURITemplateScanner * const scanner = [[STURITemplateScanner alloc] initWithString:string];
    if (!scanner) {
        return nil;
    }

    NSMutableArray * const components = [[NSMutableArray alloc] init];
    while (![scanner isAtEnd]) {
        id<STURITemplateComponent> component = nil;
        if (![scanner sturit_scanTemplateComponent:&component]) {
            return nil;
        }
        [components addObject:component];
    }

    if ((self = [super init])) {
        _components = components.copy;
    }
    return self;
}
- (NSArray *)variableNames {
    NSMutableArray * const variableNames = [[NSMutableArray alloc] init];
    for (id<STURITemplateComponent> component in _components) {
        [variableNames addObjectsFromArray:component.variableNames];
    }
    return variableNames.copy;
}
- (NSString *)string {
    return [self stringByExpandingWithVariables:nil];
}
- (NSString *)stringByExpandingWithVariables:(NSDictionary *)variables {
    NSMutableString * const urlString = [[NSMutableString alloc] init];
    for (id<STURITemplateComponent> component in _components) {
        NSString * const componentString = [component stringWithVariables:variables];
        if (!componentString) {
            return nil;
        }
        [urlString appendString:componentString];
    }
    return urlString;
}
- (NSURL *)url {
    return [self urlByExpandingWithVariables:nil];
}
- (NSURL *)urlByExpandingWithVariables:(NSDictionary *)variables {
    NSString * const urlString = [self stringByExpandingWithVariables:variables];
    return [NSURL URLWithString:urlString];
}
- (NSString *)templatedStringRepresentation {
    NSMutableString * const templatedString = [[NSMutableString alloc] init];
    for (id<STURITemplateComponent> component in _components) {
        NSString * const componentString = component.templateRepresentation;
        if (componentString.length) {
            [templatedString appendString:componentString];
        }
    }
    return templatedString.copy;
}
@end
