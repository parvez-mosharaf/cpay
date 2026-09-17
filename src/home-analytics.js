import * as amplitude from '@amplitude/unified';

// Amplitude ingestion key — public by design; move to an env var when you set up environments.
const API_KEY = '806ae864f7f83036cceb8f124d1789d3';

if (!API_KEY) {
  console.warn('Amplitude API key missing — analytics disabled');
} else {
  amplitude.initAll(API_KEY, {"analytics":{"autocapture":true},"sessionReplay":{"sampleRate":1}});
  amplitude.track('Viewed Home Page', { prompt_version: 'BA400.4' }); // helps improve this setup flow — safe to remove once you've verified the event lands
}
