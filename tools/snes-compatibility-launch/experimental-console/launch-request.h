#ifndef HC_LAUNCH_REQUEST_H
#define HC_LAUNCH_REQUEST_H
#include <stdint.h>
#include <stddef.h>
/* This frame is correlation data, not authentication. A trusted supervisor
 * must exclusively own the private pipe, select and verify the game/ROM, and
 * keep the child and descriptor alive. No message authorizes game release. */
#define HC_LAUNCH_REQUEST_SIZE 107u
typedef struct {char game[12];char digest[65];uint8_t session[16];uint64_t epoch;} HCLaunchRequest;
int hc_launch_request_encode(const HCLaunchRequest *,unsigned char[HC_LAUNCH_REQUEST_SIZE]);
int hc_launch_request_decode(const unsigned char *,size_t,HCLaunchRequest *);
int hc_launch_request_receive(int,unsigned,HCLaunchRequest *);
int hc_launch_request_send(int,const HCLaunchRequest *);
/* Prototype correlation only. A matching frame is not a shutdown proof or
 * authorization to run without an independently trusted supervisor. */
int hc_launch_release_send(int,const HCLaunchRequest *);
int hc_launch_release_receive(int,unsigned,const HCLaunchRequest *);
#endif
