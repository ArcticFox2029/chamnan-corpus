# Точка входа ExUnit. Тесты backbone намеренно не поднимают ни Kafka, ни Postgres:
# всё, что требует брокера, живёт в интеграционном наборе ops/ и гоняется на
# staging, а здесь проверяются разбор конверта и соответствие таблиц маршрутизации
# спецификации — то, что ломается чаще всего и дешевле всего ловится.

ExUnit.start(capture_log: true)
Application.put_env(:of_events, :region_code, "eu-west")
Application.put_env(:of_events, :service_name, "notification-service")
