import localUnitTest from './LocalUnit.test';
import refreshTokenChunkStoreTest from './RefreshTokenChunkStore.test';

export default function testsuite() {
  localUnitTest();
  refreshTokenChunkStoreTest();
}
