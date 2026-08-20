using System.Runtime.CompilerServices;
using System.Text;
using Confluent.Kafka;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Cienka warstwa nad klientem Kafki: subskrypcja tematu w grupie <c>OF_KAFKA_CONSUMER_GROUP</c>
/// oraz zapis na temat martwych listów. Cała logika biznesowa siedzi w konsumentach, tutaj jest
/// wyłącznie obsługa brokera — dzięki temu podmiana biblioteki nie dotyka niczego poza tym plikiem.
/// </summary>
public static class KafkaSubscription
{
    /// <summary>
    /// Czyta temat jako strumień surowych wiadomości. Zatwierdzanie przesunięcia jest ręczne
    /// i następuje po obsłudze wiadomości — przy zatwierdzaniu automatycznym restart poda
    /// gubił zdarzenia, które odebrał, ale których jeszcze nie przetworzył.
    /// </summary>
    /// <param name="options">Konfiguracja usługi.</param>
    /// <param name="topic">Temat.</param>
    /// <param name="ct">Token anulowania; zamyka konsumenta i zwalnia partycje.</param>
    public static async IAsyncEnumerable<string> ReadAsync(
        WarehouseOptions options,
        string topic,
        [EnumeratorCancellation] CancellationToken ct)
    {
        var config = new ConsumerConfig
        {
            BootstrapServers = options.KafkaBrokers,
            GroupId = options.KafkaConsumerGroup,
            EnableAutoCommit = false,
            AutoOffsetReset = AutoOffsetReset.Earliest,
            SessionTimeoutMs = 30_000
        };

        using var consumer = new ConsumerBuilder<string, string>(config).Build();
        consumer.Subscribe(topic);

        try
        {
            while (!ct.IsCancellationRequested)
            {
                var result = consumer.Consume(TimeSpan.FromMilliseconds(500));

                if (result?.Message is null)
                {
                    await Task.Yield();
                    continue;
                }

                yield return result.Message.Value;
                consumer.Commit(result);
            }
        }
        finally
        {
            consumer.Close();
        }
    }

    /// <summary>
    /// Odkłada wiadomość na temat martwych listów wraz z powodem. Powód idzie w nagłówku,
    /// a nie w ciele — ciało musi zostać bajt w bajt takie, jakie przyszło, żeby dało się je
    /// odtworzyć po naprawie błędu.
    /// </summary>
    public static async Task PublishAsync(
        WarehouseOptions options,
        string topic,
        string raw,
        Exception cause,
        CancellationToken ct)
    {
        var config = new ProducerConfig
        {
            BootstrapServers = options.KafkaBrokers,
            Acks = Acks.All,
            EnableIdempotence = true
        };

        using var producer = new ProducerBuilder<string, string>(config).Build();

        var message = new Message<string, string>
        {
            Key = Guid.NewGuid().ToString("N"),
            Value = raw,
            Headers =
            [
                new Header("of-dlq-reason", Encoding.UTF8.GetBytes(cause.GetType().Name)),
                new Header("of-dlq-message", Encoding.UTF8.GetBytes(cause.Message)),
                new Header("of-dlq-producer", Encoding.UTF8.GetBytes(options.ServiceName))
            ]
        };

        await producer.ProduceAsync(topic, message, ct);
    }
}
