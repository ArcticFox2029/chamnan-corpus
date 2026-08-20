/**
 * स्कैन का इतिहास — `freight.shipment_scan_events` की पंक्तियाँ, नई पहले।
 *
 * यह ग्राहक को दिखने वाली सबसे उपयोगी चीज़ है, इसलिए दो बातें यहाँ सोच-समझकर
 * तय की गई हैं:
 *
 *  1. **`occurred_at` दिखता है, `recorded_at` नहीं।** पहला वह क्षण है जब गोदाम
 *     में सचमुच कुछ हुआ; दूसरा वह क्षण जब सर्वर को पता चला। दोनों में कई घंटे
 *     का अंतर सामान्य है (उपकरण ऑफ़लाइन था), और ग्राहक को घटना का समय चाहिए,
 *     सर्वर का नहीं।
 *  2. **देरी का संकेत तभी जब वह असामान्य हो।** दोनों समयों का अंतर एक घंटे से
 *     ऊपर हो तो पंक्ति पर एक छोटा निशान लगता है — यह वही सीमा नहीं है जो सर्वर
 *     पर `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S` है, क्योंकि वह घड़ी के विचलन
 *     के लिए है और यह कतार में बीते समय के लिए।
 *
 * `scan_type` के आठों मान अनुवादित होकर दिखते हैं पर मान स्वयं कभी नहीं बदलता।
 */
import React from 'react';
import {FlatList, StyleSheet, Text, View} from 'react-native';

const SCAN_TYPE_LABEL = {
  gate_in: 'Gate in',
  gate_out: 'Gate out',
  load: 'Loaded',
  unload: 'Unloaded',
  seal_check: 'Seal check',
  customs_inspection: 'Customs inspection',
  damage_report: 'Damage reported',
  proof_of_delivery: 'Proof of delivery',
};

/** एक घंटे से ऊपर की देरी ही दिखाने लायक है। */
const LATE_ARRIVAL_MS = 60 * 60 * 1000;

function wasQueuedOffline(scan) {
  const occurred = Date.parse(scan.occurred_at);
  const recorded = Date.parse(scan.recorded_at);
  if (Number.isNaN(occurred) || Number.isNaN(recorded)) {
    return false;
  }
  return recorded - occurred > LATE_ARRIVAL_MS;
}

function ScanRow({scan}) {
  return (
    <View style={styles.row}>
      <View style={styles.bullet} />
      <View style={styles.body}>
        <Text style={styles.type}>{SCAN_TYPE_LABEL[scan.scan_type] ?? scan.scan_type}</Text>
        <Text style={styles.time}>{scan.occurred_at}</Text>
        {scan.container_id ? (
          <Text style={styles.container}>{scan.container_id}</Text>
        ) : null}
        {wasQueuedOffline(scan) ? (
          <Text style={styles.offline}>Recorded offline, uploaded later</Text>
        ) : null}
      </View>
    </View>
  );
}

export default function ScanTrail({scans}) {
  if (!scans || scans.length === 0) {
    // खाली सूची का अर्थ है कि इस शिपमेंट पर अब तक कुछ स्कैन नहीं हुआ — यह
    // सामान्य है (बुक होते ही ऐसा ही होता है), इसलिए यहाँ त्रुटि जैसा कुछ नहीं।
    return <Text style={styles.empty}>No scans recorded yet.</Text>;
  }

  return (
    <FlatList
      data={scans}
      keyExtractor={scan => scan.scan_id}
      renderItem={({item}) => <ScanRow scan={item} />}
      scrollEnabled={false}
    />
  );
}

const styles = StyleSheet.create({
  row: {flexDirection: 'row', paddingVertical: 10},
  bullet: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: '#0E2A47',
    marginTop: 6,
    marginRight: 12,
  },
  body: {flex: 1},
  type: {fontSize: 15, fontWeight: '600', color: '#101418'},
  time: {fontSize: 13, color: '#5F6368', marginTop: 2},
  container: {fontSize: 13, color: '#5F6368', fontVariant: ['tabular-nums']},
  offline: {fontSize: 12, color: '#8A4B08', marginTop: 4},
  empty: {fontSize: 14, color: '#5F6368', paddingVertical: 12},
});
