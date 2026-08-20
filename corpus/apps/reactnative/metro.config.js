/**
 * Metro बंडलर का विन्यास।
 *
 * डिफ़ॉल्ट से तीन जगह हटकर है, तीनों का कारण इसी रिपॉज़िटरी का आकार है:
 *
 *  1. `watchFolders` में केवल यही ऐप है। पूरे मंच की जड़ पर नज़र रखने से Metro
 *     चौदह सेवाओं, फ़र्मवेयर और db/ के हर बदलाव पर जागता था और Mac का पंखा
 *     चलता रहता था।
 *  2. `blockList` में देशी बिल्ड के फल हैं। `ios/Pods` और `android/build` में
 *     वही फ़ाइल-नाम दोबारा मिलते हैं और Metro उन्हें डुप्लिकेट मॉड्यूल मानकर
 *     बंडल तोड़ देता है।
 *  3. `sourceExts` में `.jsx` भी है। ऐप ज़्यादातर TypeScript में है, पर दो
 *     प्रस्तुति-घटक अब भी सादे JSX में हैं — उन्हें बदलने का कोई कारण नहीं मिला,
 *     वे केवल दिखाते हैं और उनमें कोई प्रकार का तर्क नहीं है।
 */
const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

const projectRoot = __dirname;

/** @type {import('metro-config').MetroConfig} */
const config = {
  projectRoot,
  watchFolders: [projectRoot],
  resolver: {
    sourceExts: ['ts', 'tsx', 'js', 'jsx', 'json'],
    blockList: [
      new RegExp(`${path.resolve(projectRoot, 'ios', 'Pods')}/.*`),
      new RegExp(`${path.resolve(projectRoot, 'android', 'build')}/.*`),
    ],
  },
  transformer: {
    // इनलाइन require से पहला फ़्रेम जल्दी आता है; ट्रैकिंग ऐप ज़्यादातर
    // सूचना पर टैप करके खुलता है, इसलिए ठंडी शुरुआत ही सामान्य शुरुआत है।
    inlineRequires: true,
  },
};

module.exports = mergeConfig(getDefaultConfig(projectRoot), config);
