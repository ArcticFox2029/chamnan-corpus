/**
 * शिपमेंट की स्थिति दिखाने वाली गोली (pill)।
 *
 * यह घटक अब भी सादे JSX में है, TypeScript में नहीं, और यह जान-बूझकर है: इसमें
 * कोई तर्क नहीं है, केवल आठ मानों का रंग और लेबल। इसे बदलने का कोई कारण अब तक
 * नहीं मिला।
 *
 * एक नियम यहाँ सख़्त है — `freight.shipments.status` के आठों मान नीचे मौजूद
 * रहने चाहिए। अनजान मान आने पर गोली उसी मान को जस का तस दिखाती है, ग़ायब नहीं
 * होती: चुपचाप कुछ न दिखाने से ग्राहक को लगता है कि शिपमेंट की कोई स्थिति ही
 * नहीं है, जबकि असल में ऐप पुराना है।
 *
 * रंगों में `at_risk` और `held_at_customs` दोनों चेतावनी वाले हैं पर अलग हैं,
 * क्योंकि उनका अर्थ अलग है: पहला सेंसर की चेतावनी से आता है
 * (`telemetry.alert.raised`), दूसरा सीमा-शुल्क से — और ग्राहक इन दोनों पर बिलकुल
 * अलग काम करता है।
 */
import React from 'react';
import {StyleSheet, Text, View} from 'react-native';

const PRESENTATION = {
  draft: {label: 'Draft', background: '#E8EAED', foreground: '#3C4043'},
  booked: {label: 'Booked', background: '#E3F0FF', foreground: '#0E2A47'},
  sealed: {label: 'Sealed', background: '#DDE7F5', foreground: '#0E2A47'},
  in_transit: {label: 'In transit', background: '#DFF3E6', foreground: '#14532D'},
  at_risk: {label: 'At risk', background: '#FDE7CF', foreground: '#8A4B08'},
  held_at_customs: {label: 'Held at customs', background: '#FBD9D9', foreground: '#7A1C1C'},
  delivered: {label: 'Delivered', background: '#E6E6E6', foreground: '#3C4043'},
  cancelled: {label: 'Cancelled', background: '#EFEFEF', foreground: '#6B6B6B'},
};

export default function StatusPill({status, compact}) {
  const presentation = PRESENTATION[status] ?? {
    label: status,
    background: '#EFEFEF',
    foreground: '#3C4043',
  };

  return (
    <View
      style={[
        styles.pill,
        compact ? styles.compact : null,
        {backgroundColor: presentation.background},
      ]}>
      <Text style={[styles.label, {color: presentation.foreground}]}>
        {presentation.label}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  pill: {
    alignSelf: 'flex-start',
    borderRadius: 12,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  compact: {
    paddingHorizontal: 8,
    paddingVertical: 2,
  },
  label: {
    fontSize: 13,
    fontWeight: '600',
  },
});
