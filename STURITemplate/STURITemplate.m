//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
//  Copyright (c) 2014 Scott Talbot.

#import "STURITemplate.h"
#import "STURITemplate+Internal.h"
#import "STURITemplateParser.h"


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
    NSArray * const components = sturitemplate_parse(string);
    if (!components) {
        return nil;
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
