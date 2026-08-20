/**
 * एक शिपमेंट का पूरा दृश्य: स्थिति, डिब्बे, सील और स्कैन का इतिहास।
 *
 * यह स्क्रीन दो रास्तों से खुलती है और दोनों को संभालना पड़ता है:
 *
 *  • सूची से टैप — तब शिपमेंट पहले से भंडार में है और स्क्रीन तुरंत कुछ दिखा
 *    सकती है, फिर पूरा दृश्य ताज़ा कर लेती है।
 *  • सूचना से टैप — तब भंडार खाली है। notification-service की सूचना में
 *    `shipment_id` होता है और बस; इसलिए यहाँ खाली अवस्था को सामान्य मानकर
 *    लिखा गया है, अपवाद मानकर नहीं।
 *
 * **`declared_value_minor` यहाँ नहीं है और न आ सकता है।** साझेदार सतह उसे अपने
 * उत्तर से हटा देती है (§3.11) — वह मान `freight.shipments` में है पर ग्राहक
 * के दृश्य में कभी नहीं जाता। चालान की राशियाँ अलग बात हैं: वे
 * `GET /partner/v1/invoices/{invoice_id}` से आती हैं, जहाँ हर राशि पूर्णांक
 * लघु-इकाइयों में और अपनी मुद्रा के साथ होती है (§0.2)।
 */
import React, {useEffect} from 'react';
import {ActivityIndicator, ScrollView, StyleSheet, Text, View} from 'react-native';
import ScanTrail from '../components/ScanTrail';
import StatusPill from '../components/StatusPill';
import {loadShipmentDetail} from '../store/shipmentsSlice';
import {useAppDispatch, useAppSelector} from '../store';
import {scansOf} from '../api/partnerPortal';

interface Props {
  route: {params: {shipmentId: string}};
}

export default function ShipmentDetailScreen({route}: Props): React.JSX.Element {
  const dispatch = useAppDispatch();
  const {shipmentId} = route.params;
  const shipment = useAppSelector(state => state.shipments.byId[shipmentId]);

  useEffect(() => {
    // सूची वाली पंक्ति में डिब्बे और स्कैन नहीं होते, इसलिए यह हर बार चलता है —
    // भंडार में पंक्ति होने पर भी। जो दिखता है वह तुरंत दिखता है और पूरा दृश्य
    // कुछ सौ मिलीसेकंड में उसे बदल देता है।
    void dispatch(loadShipmentDetail(shipmentId));
  }, [dispatch, shipmentId]);

  if (shipment === undefined) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator />
      </View>
    );
  }

  const scans = scansOf(shipment);

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <View style={styles.header}>
        <Text style={styles.reference}>{shipment.reference}</Text>
        <StatusPill status={shipment.status} />
      </View>

      <Text style={styles.route}>
        {shipment.origin_facility_id} → {shipment.destination_facility_id}
      </Text>
      <Text style={styles.meta}>
        {shipment.incoterm} · {shipment.region_code}
      </Text>

      {shipment.status === 'at_risk' ? (
        // `at_risk` में शिपमेंट सेंसर की चेतावनी से आता है — container-registry
        // उसे `telemetry.alert.raised` सुनकर बदलता है, किसी के बुलाने पर नहीं।
        <View style={styles.riskBox}>
          <Text style={styles.riskText}>
            A sensor alert was raised on this shipment. Operations have been notified.
          </Text>
        </View>
      ) : null}

      {shipment.status === 'held_at_customs' ? (
        <View style={styles.customsBox}>
          <Text style={styles.customsText}>
            Held at customs. Clearance follows once the declaration is accepted.
          </Text>
        </View>
      ) : null}

      <Text style={styles.sectionTitle}>Containers</Text>
      {shipment.containers.map(container => (
        <View key={container.container_id} style={styles.containerRow}>
          {/* BIC कोड ग्राहक भी पहचानता है; cnt_ पहचान नहीं दिखाई जाती। */}
          <Text style={styles.isoCode}>{container.iso_code}</Text>
          <Text style={styles.containerMeta}>
            {container.iso_size_type}
            {container.is_reefer ? ' · reefer' : ''} · {container.gross_kg} kg
          </Text>
          {/* सील जोड़ी की संपत्ति है — वही डिब्बा अगले शिपमेंट पर दूसरी सील के साथ होगा। */}
          <Text style={styles.seal}>Seal {container.seal_number}</Text>
        </View>
      ))}

      <Text style={styles.sectionTitle}>Scan history</Text>
      <ScanTrail scans={scans} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#FAFAF7'},
  content: {padding: 16, paddingBottom: 48},
  loading: {flex: 1, alignItems: 'center', justifyContent: 'center'},
  header: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center'},
  reference: {fontSize: 22, fontWeight: '700', color: '#101418'},
  route: {fontSize: 15, color: '#3C4043', marginTop: 12},
  meta: {fontSize: 13, color: '#5F6368', marginTop: 4},
  riskBox: {backgroundColor: '#FDE7CF', borderRadius: 8, padding: 12, marginTop: 16},
  riskText: {color: '#8A4B08', fontSize: 14},
  customsBox: {backgroundColor: '#FBD9D9', borderRadius: 8, padding: 12, marginTop: 16},
  customsText: {color: '#7A1C1C', fontSize: 14},
  sectionTitle: {fontSize: 16, fontWeight: '700', marginTop: 24, color: '#101418'},
  containerRow: {backgroundColor: '#FFFFFF', borderRadius: 8, padding: 12, marginTop: 8},
  isoCode: {fontSize: 16, fontWeight: '600', color: '#101418'},
  containerMeta: {fontSize: 13, color: '#5F6368', marginTop: 2},
  seal: {fontSize: 13, color: '#3C4043', marginTop: 4},
});
