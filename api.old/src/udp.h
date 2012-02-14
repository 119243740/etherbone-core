/* Copyright (C) 2011 GSI GmbH.
 *
 * Author: Wesley W. Terpstra <w.terpstra@gsi.de>
 */
#ifndef UDP_BSD_H
#define UDP_BSD_H

#include "../etherbone.h"

#ifdef __WIN32
#define USE_WINSOCK
#endif

#ifdef USE_WINSOCK
#include <winsock2.h>
#else
#include <netinet/in.h>
#include <linux/if_packet.h>
#endif

#define UDP_SEGMENT_SIZE 1472

#define PROTO_ETHERNET	1
#define PROTO_UDP	2

typedef struct udp_address {
  struct sockaddr_in sin;
#ifndef USE_WINSOCK
  struct sockaddr_ll sll;
#else
  /* !!! */
#endif
} udp_address_t;

typedef struct udp_socket {
#ifndef USE_WINSOCK
  int fd;
#else
  SOCKET fd;
#endif
  int mode;
  /* for filtering in ethernet mode: */
  unsigned int ip;
  int port; 
} udp_socket_t;

#ifdef __cplusplus
extern "C" {
#endif

EB_PRIVATE int udp_socket_open(int port, int flags, udp_socket_t* result);
EB_PRIVATE void udp_socket_close(udp_socket_t sock);
EB_PRIVATE int udp_socket_resolve(udp_socket_t sock, const char* address, udp_address_t* result);
EB_PRIVATE int udp_socket_compare(udp_address_t* a, udp_address_t* b);

EB_PRIVATE int udp_socket_descriptor(udp_socket_t sock);
EB_PRIVATE int udp_socket_block(udp_socket_t sock, int timeout_us); /* Block until a read is ready */

EB_PRIVATE const unsigned char* udp_socket_recv_nb(udp_socket_t sock, udp_address_t* address, unsigned char* buf, unsigned int* len);
EB_PRIVATE void udp_socket_send(udp_socket_t sock, udp_address_t* address, unsigned char* buf, unsigned int len);

#ifdef __cplusplus
}
#endif

#endif