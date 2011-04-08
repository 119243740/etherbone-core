// Copyright (C) 2011
// GSI Helmholtzzentrum f�r Schwerionenforschung GmbH
//
// Author: M.Zweig
//

unit Global;

interface

uses etherbone,wrdevice_unit;

const
  First_DNSAdress = 'asl720.acc.gsi.de:8989';
  First_PortNumber= '400';

var
  myDNSAdress  :string;
  myAddress    :eb_address_t;
  myDevice     :Twrdevice;

  DeviceOffsetCount:Word;
  DeviceCtrRegCount:Word;
  DeviceDataCount  :Word;

  DeviceOffset:array[0..256] of LongWord;
  DeviceCtrReg:array[0..256] of LongWord;
  DeviceData  :array[0..256] of LongWord;


type TWrPacket= RECORD CASE Int64 OF
              1: (wpack: Int64);
              2: (r    : PACKED RECORD
                  data : LongWord;
                  Adr  : LongWord;
                  END;);
            END;


implementation

end.
