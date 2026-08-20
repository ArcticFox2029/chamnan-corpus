#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

//
//  OFLegacySealReader.h
//  OrbitalFreightDriver
//

NS_ASSUME_NONNULL_BEGIN

/**
 @brief Normaliza y clasifica los números de precinto leídos del código de barras del contenedor.

 @discussion
 Cada transitario imprime el precinto a su manera: con prefijo de naviera, con guiones, con ceros a
 la izquierda o con el año delante. El número que acaba en @c freight.shipment_containers.seal_number
 tiene que ser comparable entre terminales y entre países, porque de esa comparación depende que un
 escaneo de tipo @c seal_check detecte una manipulación. Esta clase es la que impone ese formato
 único, y lleva haciéndolo desde antes de que existiese la versión Swift del escáner.

 Se mantiene en Objective-C porque las reglas por transitario se han ido añadiendo una a una a lo
 largo de seis años, cada una respondiendo a un incidente concreto en un puerto concreto, y ninguna
 de ellas está documentada en otro sitio que no sea este archivo.
 */
@interface OFLegacySealReader : NSObject

/**
 @brief Deja el número de precinto en la forma canónica de la plataforma.
 @param raw Cadena tal cual la entrega @c AVCaptureMetadataOutput.
 @return Número normalizado, en mayúsculas y sin separadores. Devuelve la entrada normalizada
         aunque no reconozca el formato: perder un precinto legítimo por no tener regla para su
         transitario sería peor que guardarlo con un formato menos limpio.
 */
+ (NSString *)normalizeSealNumber:(NSString *)raw;

/**
 @brief Comprueba si dos números de precinto se refieren al mismo precinto físico.
 @discussion Compara las formas canónicas. Es lo que usa la pantalla de @c seal_check para decidir
 si el precinto que tiene delante el conductor coincide con el que consta en el envío.
 */
+ (BOOL)sealNumber:(NSString *)first matchesSealNumber:(NSString *)second;

/**
 @brief Simbologías de código de barras admitidas para precintos.
 @discussion Se pasa tal cual a @c metadataObjectTypes. No incluye QR a propósito: en las
 terminales con las que se trabaja no se usa para precintos y activarlo sólo servía para que el
 escáner leyese los carteles de la pared.
 */
+ (NSArray<AVMetadataObjectType> *)supportedSymbologies;

/**
 @brief Indica si la cadena tiene pinta de ser un precinto y no cualquier otro código.
 @discussion Filtra las etiquetas logísticas GS1-128 de la mercancía, que comparten simbología con
 los precintos de muchos transitarios y que el conductor lee sin querer al apuntar a la caja
 equivocada.
 */
+ (BOOL)looksLikeSealNumber:(NSString *)candidate;

@end

NS_ASSUME_NONNULL_END
