/** @file loopback.cpp
 *  @brief A test program which executes many many EB queries.
 *
 *  Copyright (C) 2011-2012 GSI Helmholtz Centre for Heavy Ion Research GmbH 
 *
 *  All Etherbone object types are opaque in this interface.
 *  Only those methods listed in this header comprise the public interface.
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

#include <stdio.h>
#include <stdlib.h>

#include <vector>
#include <algorithm>

#include "../etherbone.h"

using namespace etherbone;
using namespace std;

void die(const char* why, status_t error);
void test_query(Device device, int len, int requests);
void test_width(Socket socket, width_t width);

void die(const char* why, status_t error) {
  fprintf(stderr, "%s: %s\n", why, eb_status(error));
  exit(1);
}

enum RecordType { READ_BUS, READ_CFG, WRITE_BUS, WRITE_CFG };
struct Record {
  address_t address;
  data_t data;
  bool error;
  RecordType type;
};

class Echo : public Handler {
public:
  status_t read (address_t address, width_t width, data_t* data);
  status_t write(address_t address, width_t width, data_t  data);
};

status_t Echo::read (address_t address, width_t width, data_t* data) {
  return EB_OK;
}

status_t Echo::write(address_t address, width_t width, data_t  data) {
  return EB_OK;
}

class TestCycle {
public:
  std::vector<Record> records;
  int* success;

  TestCycle(Device device, int length, int* success);
  void complete(Operation op, status_t status);
};

void TestCycle::complete(Operation op, status_t status) {
  for (unsigned i = 0; i < records.size(); ++i) {
    Record& r = records[i];
    
    if (op.is_null()) die("unexpected null op", EB_FAIL);
    
    switch (r.type) {
    case READ_BUS:  if (!op.is_read() ||  op.is_config()) die("wrong op", EB_FAIL); break;
    case READ_CFG:  if (!op.is_read() || !op.is_config()) die("wrong op", EB_FAIL); break;
    case WRITE_BUS: if ( op.is_read() ||  op.is_config()) die("wrong op", EB_FAIL); break;
    case WRITE_CFG: if ( op.is_read() || !op.is_config()) die("wrong op", EB_FAIL); break;
    }
    
    if (op.address  () != r.address) die("wrong addr", EB_FAIL);
    if (op.data     () != r.data)    die("wrong data", EB_FAIL);
    if (op.had_error() != r.error)   die("wrong flag", EB_FAIL);
  }
  if (!op.is_null()) die("too many ops", EB_FAIL);
}

TestCycle::TestCycle(Device device, int length, int* success_)
 : success(success_) {
  Cycle cycle(device, this, &proxy<TestCycle, &TestCycle::complete>);
  
  for (int op = 0; op < length; ++op) {
    Record r;
    switch (r.type) {
    case READ_BUS:  cycle.read        (r.address, 0);      break;
    case READ_CFG:  cycle.read_config (r.address, 0);      break;
    case WRITE_BUS: cycle.write       (r.address, r.data); break;
    case WRITE_CFG: cycle.write_config(r.address, r.data); break;
    }
    records.push_back(r);
  }
}

void test_query(Device device, int len, int requests) {
  std::vector<int> cuts;
  std::vector<int>::iterator i;
  int success, timeout;
  
  cuts.push_back(0);
  cuts.push_back(len);
  for (int cut = 1; cut < requests; ++cut)
    cuts.push_back(random() % len);
  sort(cuts.begin(), cuts.end());
  
  /* Prepare each cycle */
  for (i = cuts.begin(); i+1 != cuts.end(); ++i) {
    int amount = *(i+1) - *i;
    TestCycle(device, amount, &success);
  }
  
  /* Flush the queries */
  device.flush();
  
  /* Wait until all complete successfully */
  timeout = 1000000; /* 1 second */
  Socket socket = device.socket();
  while (success < requests && timeout > 0) {
    timeout -= socket.block(timeout);
    socket.poll();
  }
  
  if (timeout < 0) die("waiting for loopback success", EB_TIMEOUT);
}

void test_width(Socket socket, width_t width) {
  Device device;
  status_t err;
  
  if ((err = device.open(socket, "udp/localhost/8183", width)) != EB_OK) die("device.open", err);
  
  for (int len = 0; len < 4000; ++len)
    for (int requests = 0; requests <= 9; ++requests)
      for (int repetitions = 0; repetitions < 100; ++repetitions)
        test_query(device, len, requests);
    
  if ((err = device.close()) != EB_OK) die("device.close", err);
}  

int main() {
  status_t err;
  
  Socket socket;
  if ((err = socket.open(8183)) != EB_OK) die("socket.open", err);
  
  Echo echo;
  if ((err = socket.attach(0, ~0, &echo)) != EB_OK) die("socket.attach", err);
  
  /* for widths */
  test_width(socket, EB_DATAX | EB_ADDRX);
  return 0;
}
