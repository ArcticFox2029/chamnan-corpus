// -----------------------------------------------------------------------------------------------
//  ORBITALFREIGHT · warehouse-service
//  (c) ORBITALFREIGHT Platform Group. Kod wewnętrzny, nie do dystrybucji poza organizację.
// -----------------------------------------------------------------------------------------------

using System.Text.RegularExpressions;

namespace OrbitalFreight.Warehouse.Domain.Model;

/// <summary>
/// Strażnik konwencji identyfikatorów z §0.1 specyfikacji: każdy klucz główny to ULID
/// z zachowanym prefiksem, a prefiks nigdy nie jest obcinany w transporcie. Klasa istnieje po to,
/// żeby cudzy identyfikator (np. <c>cnt_</c> z container-registry) nie trafił omyłkowo do kolumny
/// oczekującej naszego <c>slt_</c> — takie pomyłki przeszłyby przez typ <see cref="string"/> bez śladu.
/// </summary>
public static class PrefixedId
{
    /// <summary>Prefiksy encji, których właścicielem jest warehouse-service (schemat <c>warehouse</c>).</summary>
    public const string Zone = "wzn_";

    /// <inheritdoc cref="Zone"/>
    public const string Slot = "slt_";

    /// <inheritdoc cref="Zone"/>
    public const string Placement = "plc_";

    /// <inheritdoc cref="Zone"/>
    public const string PutawayRule = "wpr_";

    /// <inheritdoc cref="Zone"/>
    public const string PickWave = "pkw_";

    /// <inheritdoc cref="Zone"/>
    public const string PickTask = "pkt_";

    /// <inheritdoc cref="Zone"/>
    public const string CountPlan = "ccp_";

    /// <inheritdoc cref="Zone"/>
    public const string CountTask = "cct_";

    /// <inheritdoc cref="Zone"/>
    public const string Variance = "cvr_";

    /// <summary>Prefiksy cudze — wyłącznie do walidacji tego, co przychodzi z zewnątrz.</summary>
    public const string Tenant = "tnt_";

    /// <inheritdoc cref="Tenant"/>
    public const string User = "usr_";

    /// <inheritdoc cref="Tenant"/>
    public const string Facility = "fac_";

    /// <inheritdoc cref="Tenant"/>
    public const string Container = "cnt_";

    /// <inheritdoc cref="Tenant"/>
    public const string Shipment = "shp_";

    /// <inheritdoc cref="Tenant"/>
    public const string Scan = "scn_";

    /// <inheritdoc cref="Tenant"/>
    public const string Document = "doc_";

    /// <inheritdoc cref="Tenant"/>
    public const string Alert = "alr_";

    /// <inheritdoc cref="Tenant"/>
    public const string Declaration = "dcl_";

    // 26 znaków Crockford base32 po prefiksie; litery I, L, O i U są z alfabetu wykluczone,
    // dlatego wzorzec nie jest zwykłym [A-Z0-9].
    private static readonly Regex UlidBody = new(
        "^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{26}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// Sprawdza, czy <paramref name="value"/> jest poprawnym identyfikatorem o zadanym prefiksie.
    /// </summary>
    /// <param name="value">Surowa wartość z żądania HTTP, koperty zdarzenia albo z bazy.</param>
    /// <param name="prefix">Jedna ze stałych tej klasy, np. <see cref="Slot"/>.</param>
    /// <returns><see langword="true"/>, gdy wartość ma właściwy prefiks i poprawny korpus ULID.</returns>
    public static bool IsValid(string? value, string prefix) =>
        value is not null
        && value.Length == prefix.Length + 26
        && value.StartsWith(prefix, StringComparison.Ordinal)
        && UlidBody.IsMatch(value.AsSpan(prefix.Length).ToString());

    /// <summary>
    /// Wariant rzucający — używany na granicy warstwy domenowej, gdzie zły identyfikator jest
    /// błędem programisty, a nie błędem użytkownika.
    /// </summary>
    /// <exception cref="ArgumentException">Gdy wartość nie pasuje do prefiksu.</exception>
    public static string Require(string? value, string prefix, string parameterName)
    {
        if (!IsValid(value, prefix))
        {
            throw new ArgumentException(
                $"expected an identifier with prefix '{prefix}', got '{value ?? "<null>"}'",
                parameterName);
        }

        return value!;
    }

    /// <summary>
    /// Zwraca prefiks identyfikatora bez rozstrzygania, czy go znamy. Przydaje się w logach
    /// i w kolumnie <c>owner_type</c> dokumentów wysyłanych do document-service.
    /// </summary>
    public static string PrefixOf(string value)
    {
        var underscore = value.IndexOf('_');
        return underscore < 0 ? string.Empty : value[..(underscore + 1)];
    }
}
