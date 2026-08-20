// Плагины сборки. Единственный обязательный — assembly: задание уезжает на
// кластер OF_ANALYTICS_SPARK_MASTER одним fat-JAR, потому что зависимости на
// исполнителях не устанавливаются.

addSbtPlugin("com.eed3si9n" % "sbt-assembly" % "2.2.0")
addSbtPlugin("org.scalameta" % "sbt-scalafmt" % "2.5.2")
addSbtPlugin("com.github.sbt" % "sbt-native-packager" % "1.10.0")
