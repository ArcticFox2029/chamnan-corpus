using System.Security.Cryptography;
using OrbitalFreight.Warehouse.Application.Slotting;

namespace OrbitalFreight.Warehouse.Infrastructure;

/// <summary>
/// Wytwarza identyfikatory zgodne z §0.1: prefiks encji plus 26 znaków ULID-a w alfabecie
/// Crockford base32. Pierwsze dziesięć znaków koduje czas w milisekundach, dzięki czemu klucze
/// rosną leksykograficznie — indeks B-drzewa dopisuje wtedy na końcu zamiast rozbijać strony
/// w środku, co przy kilkuset zadaniach kompletacji na zmianę robi widoczną różnicę.
/// </summary>
public sealed class UlidIdentifierFactory : IIdentifierFactory
{
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    /// <inheritdoc />
    public string NewId(string prefix)
    {
        Span<char> buffer = stackalloc char[26];
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        for (var i = 9; i >= 0; i--)
        {
            buffer[i] = Alphabet[(int)(timestamp & 31)];
            timestamp >>= 5;
        }

        Span<byte> entropy = stackalloc byte[16];
        RandomNumberGenerator.Fill(entropy);

        for (var i = 0; i < 16; i++)
        {
            buffer[10 + i] = Alphabet[entropy[i] & 31];
        }

        return string.Concat(prefix, new string(buffer));
    }
}
