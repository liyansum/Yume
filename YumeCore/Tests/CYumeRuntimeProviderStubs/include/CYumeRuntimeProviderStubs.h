#ifndef C_YUME_RUNTIME_PROVIDER_STUBS_H
#define C_YUME_RUNTIME_PROVIDER_STUBS_H
void yume_test_provider_enable(int acknowledge_stop);
void yume_test_provider_fail_create(void);
int yume_test_provider_destroy_count(void);
int yume_test_provider_off_main_count(void);
#endif
