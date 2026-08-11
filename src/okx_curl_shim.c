#define CURL_STATICLIB 1
#include <curl/curl.h>
#include <string.h>

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
     curl_easy_setopt(easy, CURLOPT_POSTFIELDS, body_len ? body : "") != CURLE_OK ||
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
