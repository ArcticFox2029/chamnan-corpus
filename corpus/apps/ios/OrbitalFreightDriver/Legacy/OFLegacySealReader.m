//
//  OFLegacySealReader.m
//  OrbitalFreightDriver
//

#import "OFLegacySealReader.h"

/**
 Implementación de las reglas de formato de precinto acumuladas desde 2019.

 Es el archivo que decide qué se guarda en @c freight.shipment_containers.seal_number, y por tanto
 el que determina si un escaneo de tipo @c seal_check detecta una manipulación o la deja pasar. Cada
 regla de aquí abajo lleva escrito de dónde salió, porque ninguna se puede quitar sin saber a qué
 puerto de qué país deja de dar servicio.
 */

/**
 Prefijos de transitario que se retiran al normalizar.

 Cada uno entró aquí por un incidente distinto. El de @c SEAL- venía de una terminal de Rotterdam
 que lo imprimía en el código de barras pero no en la etiqueta impresa, de modo que el conductor
 leía una cosa y el albarán decía otra; el de @c ES- lo añade una empresa de precintos española sólo
 en los envíos de exportación. La lista está ordenada de más largo a más corto y ese orden es
 obligatorio: con @c S- antes que @c SEAL-, el primer prefijo se comía la S y dejaba @c EAL-1234.
 */
static NSArray<NSString *> *OFSealPrefixes(void)
{
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[ @"SEAL-", @"SEAL", @"PRE-", @"ES-", @"NL-", @"DE-", @"S-" ];
    });
    return prefixes;
}

@implementation OFLegacySealReader

+ (NSString *)normalizeSealNumber:(NSString *)raw
{
    if (raw.length == 0) {
        return @"";
    }

    NSString *working = [raw uppercaseString];

    // 1. Fuera separadores. Guiones, espacios, barras y puntos aparecen en todas las combinaciones
    //    imaginables y ninguno lleva información.
    NSMutableString *stripped = [NSMutableString stringWithCapacity:working.length];
    for (NSUInteger i = 0; i < working.length; i++) {
        unichar c = [working characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            [stripped appendFormat:@"%C", c];
        }
    }

    // 2. Fuera el prefijo de transitario, si lo hay. Se comprueba sobre la cadena con separadores
    //    porque los prefijos los llevan y sobre la limpia porque a veces no.
    NSString *candidate = [stripped copy];
    for (NSString *prefix in OFSealPrefixes()) {
        NSString *bare = [prefix stringByReplacingOccurrencesOfString:@"-" withString:@""];
        if (bare.length > 0 && [candidate hasPrefix:bare] && candidate.length > bare.length + 4) {
            candidate = [candidate substringFromIndex:bare.length];
            break;
        }
    }

    // 3. Ceros a la izquierda. Los precintos numéricos se imprimen rellenados a ocho posiciones en
    //    unos sitios y a seis en otros, y el mismo precinto físico llegaba como 00123456 y como
    //    123456 según quién lo leyese. Se recortan sólo si lo que queda es todo numérico: en un
    //    código alfanumérico el cero inicial sí puede ser significativo.
    if ([self isAllDigits:candidate]) {
        NSUInteger firstNonZero = 0;
        while (firstNonZero < candidate.length - 1 && [candidate characterAtIndex:firstNonZero] == '0') {
            firstNonZero++;
        }
        candidate = [candidate substringFromIndex:firstNonZero];
    }

    return candidate;
}

+ (BOOL)sealNumber:(NSString *)first matchesSealNumber:(NSString *)second
{
    NSString *a = [self normalizeSealNumber:first];
    NSString *b = [self normalizeSealNumber:second];
    if (a.length == 0 || b.length == 0) {
        return NO;
    }
    return [a isEqualToString:b];
}

+ (NSArray<AVMetadataObjectType> *)supportedSymbologies
{
    return @[ AVMetadataObjectTypeCode128Code,
              AVMetadataObjectTypeCode39Code,
              AVMetadataObjectTypeInterleaved2of5Code ];
}

+ (BOOL)looksLikeSealNumber:(NSString *)candidate
{
    NSString *normalized = [self normalizeSealNumber:candidate];

    // Los precintos que hemos visto en producción van de seis a quince caracteres. Por debajo de
    // seis casi siempre es una lectura parcial de la etiqueta.
    if (normalized.length < 6 || normalized.length > 15) {
        return NO;
    }

    // Las etiquetas logísticas GS1-128 empiezan por un identificador de aplicación entre
    // paréntesis, que el lector entrega ya sin ellos. El (00) del SSCC es el que más se cuela:
    // dieciocho dígitos empezando por 00, que es demasiado largo para un precinto y ya lo ha
    // descartado la comprobación de longitud. El (01) del GTIN sí encaja en longitud y hay que
    // filtrarlo aquí.
    if (normalized.length == 14 && [normalized hasPrefix:@"01"] && [self isAllDigits:normalized]) {
        return NO;
    }

    // Un precinto siempre tiene al menos un dígito. Una lectura sólo de letras es texto de la
    // etiqueta, no el número.
    BOOL hasDigit = NO;
    for (NSUInteger i = 0; i < normalized.length; i++) {
        unichar c = [normalized characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            hasDigit = YES;
            break;
        }
    }
    return hasDigit;
}

+ (BOOL)isAllDigits:(NSString *)string
{
    if (string.length == 0) {
        return NO;
    }
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        if (c < '0' || c > '9') {
            return NO;
        }
    }
    return YES;
}

@end
