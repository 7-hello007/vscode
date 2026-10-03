import localUnitTest from './LocalUnit.test';
import refreshTokenChunkStoreTest from './RefreshTokenChunkStore.test';
import pluginPlatformTest from './PluginPlatform.test';

export default function testsuite() {
  localUnitTest();
  refreshTokenChunkStoreTest();
  pluginPlatformTest();
}
