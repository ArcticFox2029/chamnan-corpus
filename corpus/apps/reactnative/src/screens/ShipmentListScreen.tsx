/**
 * ग्राहक की मुख्य स्क्रीन — उसके शिपमेंट, चालू पहले।
 *
 * सूची `GET /partner/v1/shipments` से आती है और पहले से छँटी हुई होती है:
 * साझेदार को केवल वही शिपमेंट दिखते हैं जिन्हें उसकी carrier या broker भूमिका
 * छूती है। इसलिए यहाँ कोई tenant-स्तरीय छँटाई नहीं है और उसे जोड़ना भी नहीं
 * चाहिए — वह निर्णय सर्वर पर होता है, जहाँ भूमिकाएँ सचमुच पता हैं।
 *
 * पेजिनेशन कर्सर-आधारित है (§0.5): सूची के अंत तक पहुँचने पर अगला पेज
 * `next_cursor` से माँगा जाता है, और उसका `null` होना ही अंत है। इसीलिए यहाँ
 * "कुल कितने" जैसी कोई संख्या नहीं दिखती — वह सर्वर देता ही नहीं, और गिनने के
 * लिए पूरी सूची खींचना दर-सीमा को छूने का सबसे सीधा रास्ता है।
 */
import React, {useCallback, useEffect} from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import StatusPill from '../components/StatusPill';
import {loadShipments} from '../store/shipmentsSlice';
import {selectOrderedShipments, useAppDispatch, useAppSelector} from '../store';
import type {TrackedShipment} from '../api/partnerPortal';

interface Props {
  navigation: {navigate: (screen: string, params: {shipmentId: string}) => void};
}

/**
 * `error.code` से दिखने वाला संदेश।
 *
 * कोड ही चुना जाता है, `message` नहीं: `message` में खुली पहचानें होती हैं
 * (shp_…) और वह सहायता-डेस्क के लिए लिखा गया है, ग्राहक के लिए नहीं।
 */
function messageForCode(code: string): string {
  switch (code) {
    case 'network_unreachable':
      return 'No connection. Pull down to try again.';
    case 'session_required':
      return 'Your session has ended. Sign in again.';
    case 'rate_limited':
      return 'Too many requests. Try again in a minute.';
    case 'gateway_error':
      return 'The service is briefly unavailable.';
    default:
      return 'Something went wrong while loading your shipments.';
  }
}

export default function ShipmentListScreen({navigation}: Props): React.JSX.Element {
  const dispatch = useAppDispatch();
  const shipments = useAppSelector(selectOrderedShipments);
  const {loading, nextCursor, errorCode} = useAppSelector(state => state.shipments);

  useEffect(() => {
    void dispatch(loadShipments({refresh: true}));
  }, [dispatch]);

  const loadNextPage = useCallback(() => {
    // `null` कर्सर का अर्थ है सूची पूरी हो चुकी; दोबारा माँगना पहला पेज दोहराएगा।
    if (nextCursor !== null && !loading) {
      void dispatch(loadShipments({refresh: false}));
    }
  }, [dispatch, loading, nextCursor]);

  const renderItem = useCallback(
    ({item}: {item: TrackedShipment}) => (
      <Pressable
        style={styles.card}
        onPress={() => navigation.navigate('ShipmentDetail', {shipmentId: item.shipment_id})}>
        <View style={styles.cardHeader}>
          {/* ग्राहक की अपनी बुकिंग संख्या; shp_ पहचान यहाँ नहीं दिखती, क्योंकि
              ग्राहक उसे कभी बोलता नहीं — वह हमेशा अपनी reference बताता है। */}
          <Text style={styles.reference}>{item.reference}</Text>
          <StatusPill status={item.status} compact />
        </View>
        <Text style={styles.route}>
          {item.origin_facility_id} → {item.destination_facility_id}
        </Text>
        <Text style={styles.meta}>
          {item.incoterm} · {item.containers.length} container(s)
        </Text>
        {item.sla_deadline_at !== null && item.delivered_at === null ? (
          <Text style={styles.deadline}>Due {item.sla_deadline_at}</Text>
        ) : null}
      </Pressable>
    ),
    [navigation],
  );

  return (
    <View style={styles.screen}>
      {errorCode !== null ? (
        <View style={styles.banner}>
          <Text style={styles.bannerText}>{messageForCode(errorCode)}</Text>
        </View>
      ) : null}

      <FlatList
        data={shipments}
        keyExtractor={shipment => shipment.shipment_id}
        renderItem={renderItem}
        onEndReached={loadNextPage}
        onEndReachedThreshold={0.4}
        refreshControl={
          <RefreshControl
            refreshing={loading && shipments.length === 0}
            onRefresh={() => dispatch(loadShipments({refresh: true}))}
          />
        }
        ListFooterComponent={
          loading && shipments.length > 0 ? (
            <ActivityIndicator style={styles.footer} />
          ) : null
        }
        ListEmptyComponent={
          loading ? null : <Text style={styles.empty}>No shipments to show.</Text>
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#FAFAF7'},
  banner: {backgroundColor: '#FBD9D9', padding: 12},
  bannerText: {color: '#7A1C1C', fontSize: 14},
  card: {
    backgroundColor: '#FFFFFF',
    borderRadius: 10,
    marginHorizontal: 12,
    marginTop: 12,
    padding: 14,
  },
  cardHeader: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center'},
  reference: {fontSize: 17, fontWeight: '700', color: '#101418'},
  route: {fontSize: 14, color: '#3C4043', marginTop: 8},
  meta: {fontSize: 13, color: '#5F6368', marginTop: 4},
  deadline: {fontSize: 13, color: '#8A4B08', marginTop: 6},
  footer: {marginVertical: 16},
  empty: {textAlign: 'center', marginTop: 48, color: '#5F6368'},
});
