//
//  OFLegacyContainerCodeValidator.m
//  OrbitalFreightDriver
//
//  Copyright (c) 2019-2026 ORBITALFREIGHT. Todos los derechos reservados.
//

#import "OFLegacyContainerCodeValidator.h"

/**
 Implementación del filtro que decide qué códigos de contenedor pueden salir del terminal.

 El único cliente real es la cámara: @c OFScanCaptureController pasa por aquí cada candidato de once
 caracteres antes de dejar que @c OFScanSubmissionService lo resuelva contra
 @c container-registry. Lo que se rechaza aquí no llega a la red, y lo que se acepta se convierte
 tarde o temprano en una fila de @c freight.shipment_scan_events.
 */

/**
 Tabla de valores de la norma ISO 6346 para las letras.

 A vale 10 y a partir de ahí se incrementa saltando todos los múltiplos de 11 (11, 22, 33). Esa
 exclusión es la razón por la que no se puede calcular con una fórmula lineal a partir del código
 ASCII, y es exactamente el atajo que alguien intentó introducir en 2021: el resultado validaba mal
 todo lo que llevase L, V o cualquier letra posterior.
 */
static NSUInteger OFLetterValue(unichar letter)
{
    static const NSUInteger table[26] = {
        10, 12, 13, 14, 15, 16, 17, 18, 19, 20,   // A-J
        21, 23, 24, 25, 26, 27, 28, 29, 30, 31,   // K-T
        32, 34, 35, 36, 37, 38                    // U-Z
    };
    if (letter < 'A' || letter > 'Z') {
        return NSNotFound;
    }
    return table[letter - 'A'];
}

@implementation OFLegacyContainerCodeValidator

+ (BOOL)isValidISO6346:(NSString *)code
{
    if (code.length != 11) {
        return NO;
    }

    NSString *normalized = [self normalizeReading:code];
    if (normalized.length != 11) {
        return NO;
    }

    // Estructura: cuatro letras (tres de propietario más la categoría de equipo) y siete dígitos,
    // de los cuales el último es el de control.
    for (NSUInteger i = 0; i < 4; i++) {
        unichar c = [normalized characterAtIndex:i];
        if (c < 'A' || c > 'Z') {
            return NO;
        }
    }
    for (NSUInteger i = 4; i < 11; i++) {
        unichar c = [normalized characterAtIndex:i];
        if (c < '0' || c > '9') {
            return NO;
        }
    }

    // La cuarta letra es la categoría de equipo. La norma sólo define tres valores y en la práctica
    // toda la flota que tocamos es U; J y Z aparecen en equipo desmontable y en chasis, y también
    // se aceptan porque `fleet.vehicles.vehicle_class` incluye 'chassis'.
    unichar category = [normalized characterAtIndex:3];
    if (category != 'U' && category != 'J' && category != 'Z') {
        return NO;
    }

    NSUInteger expected = [self checkDigitForPrefix:[normalized substringToIndex:10]];
    if (expected == NSNotFound) {
        return NO;
    }

    NSUInteger actual = (NSUInteger)([normalized characterAtIndex:10] - '0');
    return expected == actual;
}

+ (NSUInteger)checkDigitForPrefix:(NSString *)prefix
{
    if (prefix.length != 10) {
        return NSNotFound;
    }

    NSUInteger sum = 0;
    for (NSUInteger position = 0; position < 10; position++) {
        unichar character = [prefix characterAtIndex:position];
        NSUInteger value;

        if (character >= 'A' && character <= 'Z') {
            value = OFLetterValue(character);
        } else if (character >= '0' && character <= '9') {
            value = (NSUInteger)(character - '0');
        } else {
            return NSNotFound;
        }

        if (value == NSNotFound) {
            return NSNotFound;
        }

        // El peso es 2^posición: 1, 2, 4, 8… hasta 512 en la décima posición.
        sum += value * (NSUInteger)(1 << position);
    }

    NSUInteger remainder = sum % 11;

    // El caso del 10 es el que se le escapa a todo el mundo: la norma dice que un resto de 10 se
    // escribe como 0, no que el código sea inválido. Rechazarlo nos hizo descartar contenedores
    // perfectamente legítimos durante las dos primeras semanas de producción, y el patrón era tan
    // aleatorio que costó un mes reproducirlo.
    return remainder % 10;
}

+ (NSString *)normalizeReading:(NSString *)raw
{
    if (raw == nil) {
        return @"";
    }
    NSMutableString *result = [NSMutableString stringWithCapacity:11];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            [result appendFormat:@"%C", c];
        } else if (c >= 'a' && c <= 'z') {
            [result appendFormat:@"%C", (unichar)(c - 32)];
        }
        // El resto —espacios, guiones, los puntos que algunas navieras pintan entre bloques— se
        // descarta en silencio. En la puerta del contenedor el código va separado en grupos y la
        // cámara lo lee tal cual.
    }
    return [result copy];
}

+ (nullable NSString *)repairAmbiguousReading:(NSString *)raw
{
    NSString *code = [self normalizeReading:raw];
    if (code.length != 11) {
        return nil;
    }

    // Confusiones habituales del reconocimiento óptico sobre pintura desgastada, en las dos
    // direcciones. La zona del código decide cuál de las dos se aplica.
    static NSDictionary<NSString *, NSString *> *toLetter = nil;
    static NSDictionary<NSString *, NSString *> *toDigit = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        toLetter = @{ @"0": @"O", @"1": @"I", @"5": @"S", @"8": @"B", @"2": @"Z" };
        toDigit  = @{ @"O": @"0", @"I": @"1", @"S": @"5", @"B": @"8", @"Z": @"2", @"Q": @"0" };
    });

    NSMutableString *candidate = [code mutableCopy];

    for (NSUInteger i = 0; i < 11; i++) {
        NSString *current = [code substringWithRange:NSMakeRange(i, 1)];
        NSString *replacement = (i < 4) ? toLetter[current] : toDigit[current];
        if (replacement == nil) {
            continue;
        }

        [candidate replaceCharactersInRange:NSMakeRange(i, 1) withString:replacement];
        if ([self isValidISO6346:candidate]) {
            return [candidate copy];
        }
        // Se deshace y se sigue: sólo se admite una corrección por lectura. Permitir dos abría la
        // puerta a "arreglar" un código hasta convertirlo en otro contenedor real, que es
        // exactamente el fallo que ninguna validación posterior detectaría.
        [candidate replaceCharactersInRange:NSMakeRange(i, 1) withString:current];
    }

    return nil;
}

+ (nullable NSString *)ownerCodeFromISOCode:(NSString *)code
{
    NSString *normalized = [self normalizeReading:code];
    if (normalized.length < 4) {
        return nil;
    }
    return [normalized substringToIndex:3];
}

@end
