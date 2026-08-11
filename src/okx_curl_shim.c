#define CURL_STATICLIB 1
#include <curl/curl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

struct ringwin_response {
  unsigned char *bytes;
  size_t capacity;
  size_t length;
};

static size_t ringwin_write(char *bytes, size_t size, size_t count, void *opaque) {
  struct ringwin_response *response = (struct ringwin_response *)opaque;
  size_t length = size * count;
  if(size != 0 && length / size != count)
    return 0;
  if(length > response->capacity - response->length)
    return 0;
  memcpy(response->bytes + response->length, bytes, length);
  response->length += length;
  return length;
}

int ringwin_curl_global_init(void) {
  return (int)curl_global_init(CURL_GLOBAL_DEFAULT);
}

void ringwin_curl_global_cleanup(void) {
  curl_global_cleanup();
}

int ringwin_curl_probe(unsigned int required_version) {
  const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
  const char *const *protocol;
  int https = 0;
  int wss = 0;
  if(!info)
    return 1;
  if(info->version_num != required_version)
    return 2;
  if(!info->ssl_version || strncmp(info->ssl_version, "Schannel", 8) != 0)
    return 3;
  for(protocol = info->protocols; protocol && *protocol; ++protocol) {
    if(strcmp(*protocol, "https") == 0)
      https = 1;
    if(strcmp(*protocol, "wss") == 0)
      wss = 1;
  }
  return https && wss ? 0 : 4;
}

int ringwin_curl_request(const char *url, const char *method,
                         const char *const *headers, size_t header_count,
                         const unsigned char *body, size_t body_len,
                         const char *proxy,
                         unsigned char *response_bytes, size_t response_capacity,
                         size_t *response_len, long *http_status, int *curl_code) {
  CURL *easy = curl_easy_init();
  struct curl_slist *list = NULL;
  struct ringwin_response response = { response_bytes, response_capacity, 0 };
  const void *post_body = body_len ? (const void *)body : (const void *)"";
  CURLcode code;
  size_t index;
  if(!easy)
    return 1;
  for(index = 0; index < header_count; ++index) {
    struct curl_slist *next = curl_slist_append(list, headers[index]);
    if(!next) {
      curl_slist_free_all(list);
      curl_easy_cleanup(easy);
      return 1;
    }
    list = next;
  }
  if(curl_easy_setopt(easy, CURLOPT_URL, url) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, method) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "https") != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_HTTPHEADER, list) != CURLE_OK ||
     (proxy && curl_easy_setopt(easy, CURLOPT_PROXY, proxy) != CURLE_OK) ||
     curl_easy_setopt(easy, CURLOPT_POSTFIELDS, post_body) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_len) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, ringwin_write) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_WRITEDATA, &response) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, 5000L) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, 10000L) != CURLE_OK ||
     curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L) != CURLE_OK) {
    curl_slist_free_all(list);
    curl_easy_cleanup(easy);
    return 1;
  }
  code = curl_easy_perform(easy);
  *curl_code = (int)code;
  *response_len = response.length;
  if(code == CURLE_OK)
    (void)curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, http_status);
  curl_slist_free_all(list);
  curl_easy_cleanup(easy);
  return code == CURLE_OK ? 0 : 2;
}

struct ringwin_ws {
  CURL *easy;
  CURLM *multi;
  atomic_int cancelled;
};

void *ringwin_ws_create(const char *url, const char *proxy) {
  struct ringwin_ws *ws = calloc(1, sizeof(*ws));
  if(!ws)
    return NULL;
  ws->easy = curl_easy_init();
  ws->multi = curl_multi_init();
  atomic_init(&ws->cancelled, 0);
  if(!ws->easy || !ws->multi ||
     curl_easy_setopt(ws->easy, CURLOPT_URL, url) != CURLE_OK ||
     curl_easy_setopt(ws->easy, CURLOPT_PROTOCOLS_STR, "wss") != CURLE_OK ||
     curl_easy_setopt(ws->easy, CURLOPT_CONNECT_ONLY, 2L) != CURLE_OK ||
     curl_easy_setopt(ws->easy, CURLOPT_CONNECTTIMEOUT_MS, 10000L) != CURLE_OK ||
     curl_easy_setopt(ws->easy, CURLOPT_SSL_VERIFYPEER, 1L) != CURLE_OK ||
     curl_easy_setopt(ws->easy, CURLOPT_SSL_VERIFYHOST, 2L) != CURLE_OK ||
     (proxy && curl_easy_setopt(ws->easy, CURLOPT_PROXY, proxy) != CURLE_OK) ||
     curl_multi_add_handle(ws->multi, ws->easy) != CURLM_OK) {
    if(ws->multi) curl_multi_cleanup(ws->multi);
    if(ws->easy) curl_easy_cleanup(ws->easy);
    free(ws);
    return NULL;
  }
  return ws;
}

static int ringwin_ws_wait(struct ringwin_ws *ws, int timeout_ms) {
  int descriptors = 0;
  CURLMcode code;
  if(atomic_load(&ws->cancelled))
    return 3;
  code = curl_multi_poll(ws->multi, NULL, 0, timeout_ms, &descriptors);
  if(code != CURLM_OK)
    return 6;
  return atomic_load(&ws->cancelled) ? 3 : 0;
}

static unsigned long long ringwin_monotonic_ms(void) {
#ifdef _WIN32
  return (unsigned long long)GetTickCount64();
#else
  struct timespec now;
  if(clock_gettime(CLOCK_MONOTONIC, &now) != 0 && timespec_get(&now, TIME_UTC) != TIME_UTC)
    return 1;
  return (unsigned long long)now.tv_sec * 1000ULL +
         (unsigned long long)now.tv_nsec / 1000000ULL;
#endif
}

int ringwin_ws_connect(void *opaque) {
  struct ringwin_ws *ws = opaque;
  int running = 0;
  CURLMcode multi_code;
  CURLMsg *message;
  int pending;
  if(!ws)
    return 1;
  do {
    multi_code = curl_multi_perform(ws->multi, &running);
    if(multi_code != CURLM_OK)
      return 6;
    if(running) {
      int waited = ringwin_ws_wait(ws, 1000);
      if(waited) return waited;
    }
  } while(running);
  while((message = curl_multi_info_read(ws->multi, &pending)) != NULL) {
    if(message->msg == CURLMSG_DONE)
      return message->data.result == CURLE_OK ? 0 : 6;
  }
  return 6;
}

int ringwin_ws_send_text(void *opaque, const unsigned char *bytes, size_t length) {
  struct ringwin_ws *ws = opaque;
  size_t offset = 0;
  if(!ws)
    return 1;
  if(atomic_load(&ws->cancelled))
    return 3;
  while(offset < length) {
    size_t sent = 0;
    CURLcode code = curl_ws_send(ws->easy, bytes + offset, length - offset,
                                 &sent, 0, CURLWS_TEXT);
    if(code == CURLE_OK) {
      offset += sent;
      continue;
    }
    if(code != CURLE_AGAIN)
      return 6;
    {
      int waited = ringwin_ws_wait(ws, 1000);
      if(waited) return waited;
    }
  }
  return 0;
}

int ringwin_ws_recv_message(void *opaque, unsigned char *buffer, size_t capacity,
                            size_t *length, int timeout_ms) {
  struct ringwin_ws *ws = opaque;
  size_t offset = 0;
  unsigned long long deadline;
  if(!ws || !capacity || timeout_ms <= 0)
    return 1;
  if(atomic_load(&ws->cancelled))
    return 3;
  deadline = ringwin_monotonic_ms() + (unsigned int)timeout_ms;
  while(ringwin_monotonic_ms() < deadline) {
    size_t received = 0;
    const struct curl_ws_frame *meta = NULL;
    CURLcode code = curl_ws_recv(ws->easy, buffer + offset, capacity - offset,
                                 &received, &meta);
    if(code == CURLE_AGAIN) {
      unsigned long long now = ringwin_monotonic_ms();
      unsigned long long remaining;
      if(now >= deadline) return 2;
      remaining = deadline - now;
      int slice = remaining > 1000ULL ? 1000 : (int)remaining;
      int waited;
      if(slice <= 0) return 2;
      waited = ringwin_ws_wait(ws, slice);
      if(waited) return waited;
      continue;
    }
    if(code == CURLE_GOT_NOTHING)
      return 4;
    if(code != CURLE_OK || !meta)
      return 6;
    if(meta->flags & CURLWS_CLOSE)
      return 4;
    if(meta->flags & (CURLWS_PING | CURLWS_PONG))
      continue;
    if(!(meta->flags & CURLWS_TEXT))
      return 7;
    offset += received;
    if(meta->bytesleft > (curl_off_t)(capacity - offset))
      return 5;
    if(meta->bytesleft == 0 && !(meta->flags & CURLWS_CONT)) {
      *length = offset;
      return 0;
    }
    if(offset == capacity)
      return 5;
  }
  return 2;
}

int ringwin_ws_cancel(void *opaque) {
  struct ringwin_ws *ws = opaque;
  if(!ws)
    return 1;
  atomic_store(&ws->cancelled, 1);
  return curl_multi_wakeup(ws->multi) == CURLM_OK ? 0 : 6;
}

void ringwin_ws_destroy(void *opaque) {
  struct ringwin_ws *ws = opaque;
  size_t sent = 0;
  if(!ws)
    return;
  (void)curl_ws_send(ws->easy, "", 0, &sent, 0, CURLWS_CLOSE);
  (void)curl_multi_remove_handle(ws->multi, ws->easy);
  curl_easy_cleanup(ws->easy);
  curl_multi_cleanup(ws->multi);
  free(ws);
}
