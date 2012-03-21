/** @file eb-discover.c
 *  @brief A tool for discovering Etherbone devices on a network.
 *
 *  Copyright (C) 2011-2012 GSI Helmholtz Centre for Heavy Ion Research GmbH 
 *
 *  A complete skeleton of an application using the Etherbone library.
 *
 *  @author Wesley W. Terpstra <w.terpstra@gsi.de>
 *
 *  @bug None!
 *
 *******************************************************************************
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 3 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *  
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library. If not, see <http://www.gnu.org/licenses/>.
 *******************************************************************************
 */

#include "../transport/posix-udp.h"
#include "common.h"

#include <unistd.h> /* getopt */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct eb_block_readset {
  int nfd;
  fd_set rfds;
};

static int eb_update_readset(eb_user_data_t data, eb_descriptor_t fd) {
  struct eb_block_readset* set = (struct eb_block_readset*)data;
  
  if (fd > set->nfd) set->nfd = fd;
  FD_SET(fd, &set->rfds);
  
  return 0;
}

static void check(int sock) {
  struct sockaddr_storage ss;
  socklen_t sslen;
  uint8_t buf[8];
  int width;
  char host[256], port[256];
  
  sslen = sizeof(ss);
  eb_posix_ip_non_blocking(sock, 1);
  if (recvfrom(sock, &buf[0], 8, MSG_DONTWAIT, (struct sockaddr*)&ss, &sslen) != 8) return;
  if (buf[0] != 0x4E || buf[1] != 0x6F) return;
  
  if (getnameinfo((struct sockaddr*)&ss, sslen, host, sizeof(host), port, sizeof(port), NI_DGRAM) != 0) {
    strcpy(host, "unknown");
    strcpy(port, "0");
  }
  
  width = printf("udp%d/%s/%s", (ss.ss_family==PF_INET6)?6:4, host, port);
  fwrite("                                      ", 1, 34-width, stdout);
  
  printf("V.%d; data=%s-bit addr=%s-bit\n", 
    buf[2] >> 4, width_str[buf[3] & EB_DATAX], width_str[buf[3] >> 4]);
}

int main(int argc, char** argv) {
  struct eb_posix_udp_transport udp_transport;
  struct eb_link udp_link;
  struct timeval tv;
  struct eb_block_readset rs;
  struct eb_transport* transport;
  uint8_t discover[8];
  eb_status_t status;
  
  if (argc != 2) {
    fprintf(stderr, "%s: missing non-optional argument -- <broadcast-address>\n", argv[0]);
    return 1;
  }
  
#ifdef __WIN32
  wVersionRequested = MAKEWORD(2, 2);
  if (WSAStartup(wVersionRequested, &wsaData) != 0) {
    perror("Cannot initialize winsock");
    return 1;
  }
#endif
  
  transport = (struct eb_transport*)&udp_transport;
  
  if ((status = eb_posix_udp_open(transport, 0)) != EB_OK) {
    perror("Cannot open UDP port");
    return 1;
  }
  
  if ((status = eb_posix_udp_connect(transport, &udp_link, argv[1])) != EB_OK) {
    perror("Cannot resolve address");
    return 1;
  }
  
  discover[0] = 0x4E;
  discover[1] = 0x6F;
  discover[2] = 0x11; /* V1 probe */
  discover[3] = 0xFF; /* Any device will do */
  memset(&discover[4], 0, 4);
  
  /* Send the discovery packet */
  eb_posix_udp_send(transport, &udp_link, &discover[0], 8);
  
  while (1) {
    FD_ZERO(&rs.rfds);
    rs.nfd = 0;
    eb_posix_udp_fdes(transport, 0, &rs, &eb_update_readset);
  
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    
    if (select(rs.nfd+1, &rs.rfds, 0, 0, &tv) <= 0) break; /* timeout */
    check(udp_transport.socket4);
    check(udp_transport.socket6);
  }
  
  return 0;
}