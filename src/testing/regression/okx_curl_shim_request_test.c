/* Synthetic public request seam: all easy operations are replaced before the
 * production shim is included. No DNS/socket/network operation is reachable. */
#define CURL_STATICLIB 1
#include <curl/curl.h>
#define CHECK(condition) do { if(!(condition)) { fprintf(stderr, "check failed line %d: %s\n", __LINE__, #condition); exit(90); } } while(0)
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *expected_headers[2];
static int fail_init, fail_option, option_calls, perform_code, cleaned, performed;
static struct curl_slist *borrowed;
static char fake_easy;
static long fixture_http_status=200;
static int guard_fixture_mode=0;
static curl_write_callback fixture_write;
static void *fixture_write_data;
static CURL *test_easy_init(void) { return fail_init ? NULL : (CURL *)&fake_easy; }
static CURLcode test_setopt(CURL *easy, CURLoption option, ...) {
  va_list ap;
  CHECK(easy == (CURL *)&fake_easy);
  va_start(ap, option);
  if(option == CURLOPT_HTTPHEADER) {
    struct curl_slist *node = va_arg(ap, struct curl_slist *);
    borrowed = node;
#ifdef RINGWIN_SHIM_NO_MAIN
    size_t count=0;
    for(;node;node=node->next) {
      CHECK(node->data);
      if(count == 0) CHECK(strcmp(node->data, "OK-ACCESS-KEY: key") == 0);
      if(count == 1 && !guard_fixture_mode) CHECK(strcmp(node->data, "OK-ACCESS-SIGN: uZ0OB9jFCN1FU9vKX6ED/rY/T+NyFw5os4M+UlJknIk=") == 0);
      if(count == 3) CHECK(strcmp(node->data, "OK-ACCESS-PASSPHRASE: pass") == 0);
      ++count;
    }
    CHECK(count == 6);
#else
    for(size_t i=0;i<2;++i) {
      CHECK(node && node->data == expected_headers[i]);
      node = node->next;
    }
    CHECK(!node);
#endif
  }
  else if(option == CURLOPT_WRITEFUNCTION) fixture_write = va_arg(ap,curl_write_callback);
  else if(option == CURLOPT_WRITEDATA) fixture_write_data = va_arg(ap,void *);
  va_end(ap);
  ++option_calls;
  return option_calls == fail_option ? CURLE_OUT_OF_MEMORY : CURLE_OK;
}
static CURLcode test_perform(CURL *easy) {
  CHECK(easy == (CURL *)&fake_easy);
  CHECK(borrowed);
#ifndef RINGWIN_SHIM_NO_MAIN
  CHECK(borrowed->data == expected_headers[0]);
#endif
  if(guard_fixture_mode && fixture_write) {
    char body[]="{\"code\":\"0\",\"data\":[]}";
    CHECK(fixture_write(body,1,sizeof(body)-1,fixture_write_data)==sizeof(body)-1);
  }
  ++performed;
  return (CURLcode)perform_code;
}
static CURLcode test_getinfo(CURL *easy, CURLINFO info, ...) {
  va_list ap;
  CHECK(easy == (CURL *)&fake_easy && info == CURLINFO_RESPONSE_CODE);
  va_start(ap, info); *va_arg(ap,long *) = fixture_http_status; va_end(ap); return CURLE_OK;
}
static void test_cleanup(CURL *easy) {
  CHECK(easy == (CURL *)&fake_easy);
  if(borrowed) CHECK(borrowed->data);
  ++cleaned;
}
#undef curl_easy_setopt
#undef curl_easy_getinfo
#define curl_easy_init test_easy_init
#define curl_easy_setopt test_setopt
#define curl_easy_perform test_perform
#define curl_easy_getinfo test_getinfo
#define curl_easy_cleanup test_cleanup
#include "../../adapters/okx/okx_curl_shim.c"

void ringwin_test_reset(int option_failure, int request_failure) {
  fail_init=0; fail_option=option_failure; perform_code=request_failure;
  cleaned=performed=option_calls=0; borrowed=NULL;
  fixture_http_status=200; guard_fixture_mode=0; fixture_write=NULL; fixture_write_data=NULL;
}
void ringwin_test_http_status(long status) { fixture_http_status=status; guard_fixture_mode=1; }
int ringwin_test_cleaned(void) { return cleaned; }
#ifndef RINGWIN_SHIM_NO_MAIN
static void run_case(int init_failure, int option_failure, int request_failure, int expected) {
  unsigned char response[16]; size_t length=0; long status=0; int code=0;
  fail_init=init_failure; fail_option=option_failure; perform_code=request_failure;
  cleaned=performed=option_calls=0; borrowed=NULL;
  int result = ringwin_curl_request("https://synthetic.invalid", "POST",
      expected_headers, 2, (const unsigned char *)"{}", 2, NULL,
      response, sizeof(response), &length, &status, &code);
  CHECK(result == expected);
  CHECK(cleaned == !init_failure);
  CHECK(performed == (!init_failure && !option_failure));
  CHECK(strcmp(expected_headers[0], "OK-ACCESS-KEY: synthetic") == 0);
}
int main(void) {
  expected_headers[0]="OK-ACCESS-KEY: synthetic";
  expected_headers[1]="OK-ACCESS-PASSPHRASE: synthetic";
  run_case(0,0,0,0);
  int option_count=option_calls;
  run_case(1,0,0,1);
  for(int i=1;i<=option_count;++i) run_case(0,i,0,1);
  run_case(0,0,CURLE_SEND_ERROR,2);
  run_case(0,0,CURLE_RECV_ERROR,2);
  {
    unsigned char output[16]; size_t length=0; long status=0; int code=0;
    const char *too_many[17] = {0};
    CHECK(ringwin_curl_request("https://synthetic.invalid", "GET", too_many, 17,
      output, 0, NULL, output, sizeof(output), &length, &status, &code) == 1);
    const char *null_header[1] = {NULL};
    CHECK(ringwin_curl_request("https://synthetic.invalid", "GET", null_header, 1,
      output, 0, NULL, output, sizeof(output), &length, &status, &code) == 1);
  }
  puts("synthetic request: borrowed headers, init failure, every option failure, send/receive failures, cleanup lifetime passed; no network");
  return 0;
}

#endif
