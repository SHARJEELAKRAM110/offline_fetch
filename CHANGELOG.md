## 0.1.0

- First release.
- `OfflineFetch` client with `get`, `post`, `put`, `patch`, `delete` and `send`.
- Retries with exponential backoff, jitter and `Retry-After` support.
- `GET` response cache with `networkFirst`, `cacheFirst`, `cacheOnly` and `networkOnly` policies.
- Offline queue for `POST`, `PUT`, `PATCH` and `DELETE`, sent in order with idempotency keys.
- Queue events stream.
- Interceptors that also run when queued requests are replayed.
- In-memory storage by default, plus `FileQueueStorage` and `FileCacheStore` in `package:offline_fetch/io.dart`.
