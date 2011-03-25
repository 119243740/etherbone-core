#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include "../etherbone.h"

eb_data_t my_read(eb_user_data_t user, eb_address_t address, eb_width_t width) {
  fprintf(stdout, "Received read to address %08"PRIx64" of %d bits\n", address, width*8);
  return 0;
}

void my_write(eb_user_data_t user, eb_address_t address, eb_width_t width, eb_data_t data) {
  fprintf(stdout, "Received write to address %08"PRIx64" of %d bits: %08"PRIx64"\n", address, width*8, data);
}

int main(int argc, const char** argv) {
  struct eb_handler handler;
  int port;
  eb_socket_t socket;
  
  if (argc != 4) {
    fprintf(stderr, "Syntax: %s <port> <address> <mask>\n", argv[0]);
    return 1;
  }
  
  port = atol(argv[1]);
  handler.base = atol(argv[2]);
  handler.mask = atol(argv[3]);
  
  handler.data = 0;
  handler.read = &my_read;
  handler.write = &my_write;
  
  if (eb_socket_open(port, 0, &socket) != EB_OK) {
    fprintf(stderr, "Failed to open Etherbone socket\n");
    return 1;
  }
  
  if (eb_socket_attach(socket, &handler) != EB_OK) {
    fprintf(stderr, "Failed to attach slave device\n");
    return 1;
  }
  
  while (1) {
    eb_socket_poll(socket);
  }
}