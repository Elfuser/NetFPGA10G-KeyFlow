#!/usr/bin/env python26

###########################################################################
#
#  NETFPGA10G www.netfpga.org
#
#  Module:
#       mkpkts_example.py
#
#  Description:
#       An example of how to use scapy to build packets.  The packet in
#       this example is then output to the console as an AXI Stream
#       transaction file.
#
#       Important: For the sake of portability (especially for Cygwin
#                  environments), specify all addresses.
#
#                  Scapy will attempt to retrieve any missing information
#                  from the operating system, which may fail in some
#                  execution environments (notably Cygwin).
#

import sys
sys.path.append('../../../../../../tools/scripts')

# NB: axitools import must preceed any scapy imports
import axitools

from scapy.layers.all import Ether, IP, TCP, Dot1Q

pktsNum = 100
pktsPort_0=[]
pktsPort_4=[]
f0 = open("stream_data_in_0.axi", "w")
#f1 = open("stream_data_in_1.axi", "w")
#f2 = open("stream_data_in_2.axi", "w")
#f3 = open("stream_data_in_3.axi", "w")
f4 = open("stream_data_in_4.axi", "w")

# Packts from port 0 to port 1 
for i in range(0, pktsNum):
    pkt = (Ether(src='f0:0d:f0:0d:f0:0d', dst='ba:be:ba:be:ba:be')/Dot1Q(vlan=12)/"Hello, NetFPGA-10G!-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

    pkt.time = i*(1e-8)
    pktsPort_0.append(pkt)


# Packts from port 4 to port 2
for i in range(0, pktsNum):
    pkt = (Ether(src='f4:4d:f4:4d:f4:4d', dst='ba:be:ba:be:ba:be')/Dot1Q(vlan=13)/"Hello, NetFPGA-10G!-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX")

    pkt.time = (i)*(1e-8)
    pktsPort_4.append(pkt)
             
             
# Write out to console
axitools.axis_dump( pktsPort_0, f0, 64, 1e-9 )
#axitools.axis_dump( pkts, f1, 64, 1e-9 )
#axitools.axis_dump( pkts, f2, 64, 1e-9 )
#axitools.axis_dump( pkts, f3, 64, 1e-9 )
axitools.axis_dump( pktsPort_4, f4, 64, 1e-9 )
