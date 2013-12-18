--! @file eb_master_top.vhd
--! @brief Top file for the EtherBone Master
--!
--! Copyright (C) 2013-2014 GSI Helmholtz Centre for Heavy Ion Research GmbH 
--!
--! Important details about its implementation
--! should go in these comments.
--!
--! @author Mathias Kreider <m.kreider@gsi.de>
--!
--------------------------------------------------------------------------------
--! This library is free software; you can redistribute it and/or
--! modify it under the terms of the GNU Lesser General Public
--! License as published by the Free Software Foundation; either
--! version 3 of the License, or (at your option) any later version.
--!
--! This library is distributed in the hope that it will be useful,
--! but WITHOUT ANY WARRANTY; without even the implied warranty of
--! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
--! Lesser General Public License for more details.
--!  
--! You should have received a copy of the GNU Lesser General Public
--! License along with this library. If not, see <http://www.gnu.org/licenses/>.
---------------------------------------------------------------------------------

--! Standard library
library IEEE;
--! Standard packages   
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.wishbone_pkg.all;
use work.eb_internals_pkg.all;
use work.eb_hdr_pkg.all;
use work.etherbone_pkg.all;
use work.wr_fabric_pkg.all;

entity eb_master_top is
generic(g_adr_bits_hi : natural := 8;
        g_mtu : natural := 32);
port(
  clk_i         : in  std_logic;
  rst_n_i       : in  std_logic;

  slave_i       : in  t_wishbone_slave_in;
  slave_o       : out t_wishbone_slave_out;
  
  src_i         : in  t_wrf_source_in;
  src_o         : out t_wrf_source_out
);
end eb_master_top;

architecture rtl of eb_master_top is

  signal s_adr_hi         : t_wishbone_address;
  signal s_cfg_rec_hdr    : t_rec_hdr;
  
  signal r_drain          : std_logic;
  signal s_dat            : t_wishbone_data;
  signal s_ack            : std_logic;
  signal s_err            : std_logic;
  signal s_stall          : std_logic;
  signal s_rst_n          : std_logic;
  signal wb_rst_n         : std_logic;
  signal s_tx_send_now    : std_logic;
   
  signal s_his_mac,  s_my_mac  : std_logic_vector(47 downto 0);
  signal s_his_ip,   s_my_ip   : std_logic_vector(31 downto 0);
  signal s_his_port, s_my_port : std_logic_vector(15 downto 0);

  signal s_tx_stb         : std_logic;
  signal s_tx_stall       : std_logic;
  signal s_tx_flush       : std_logic;
  
  signal s_skip_stb       : std_logic;
  signal s_skip_stall     : std_logic;
  signal s_length         : unsigned(15 downto 0); -- of UDP in words
  signal s_max_ops        : unsigned(15 downto 0); -- max eb ops count per packet
  signal s_slave_i        : t_wishbone_slave_in; 

  signal s_master_o       : t_wishbone_master_out;
  signal s_master_i       : t_wishbone_master_in; 

  signal s_framer2narrow  : t_wishbone_master_out;
  signal s_narrow2framer  : t_wishbone_master_in;
  signal s_narrow2tx      : t_wishbone_master_out;
  signal s_tx2narrow      : t_wishbone_master_in;
     
  constant c_dat_bit : natural := t_wishbone_address'left - g_adr_bits_hi +2;
  constant c_rw_bit  : natural := t_wishbone_address'left - g_adr_bits_hi +1;
  
begin
-- instances:
-- eb_fifo
-- eb_master_wb_if
-- eb_framer
-- eb_eth_tx
-- eb_stream_narrow

  s_tx_stb      <= s_tx_flush;
  s_tx_stall    <= '0';
  s_skip_stb    <= '0';
  
  s_rst_n       <= rst_n_i; -- and wb_rst_n
  
  --SLAVE IF
  slave_o.dat   <= s_dat;
  slave_o.ack   <= s_ack;
  slave_o.err   <= s_err;
  slave_o.stall <= s_stall;
  slave_o.int   <= '0';
  slave_o.rty   <= '0';
  
   wbif: eb_master_wb_if
   generic map (g_adr_bits_hi => g_adr_bits_hi)
    PORT MAP (
  clk_i       => clk_i,
  rst_n_i     => rst_n_i,

  wb_rst_n_o  => wb_rst_n,
  flush_o     => open,

  slave_i     => slave_i,
  slave_dat_o => s_dat,
  slave_ack_o => s_ack,
  slave_err_o => s_err,
  
  my_mac_o    => s_my_mac,
  my_ip_o     => s_my_ip,
  my_port_o   => s_my_port,
  
  his_mac_o   => s_his_mac, 
  his_ip_o    => s_his_ip,
  his_port_o  => s_his_port,
  length_o    => s_length,
  max_ops_o   => s_max_ops,
  adr_hi_o    => s_adr_hi,
  eb_opt_o    => s_cfg_rec_hdr
  );
  
  
  s_slave_i.dat <= slave_i.dat;
  s_slave_i.sel <= slave_i.sel;

  -- address layout: 
  --    
  --  -----------
  --  |         |
  --  |         |
  --  |  ctrl   |
  --  |_________|
  --  |  Read   |
  --  |_________|
  --  |  Write  |
  --  |_________|   

  s_tx_send_now         <= '1' when slave_i.adr(c_dat_bit) = '0' and slave_i.stb = '1' and slave_i.adr(7 downto 0) = x"04"
              else '0';
              
  s_slave_i.cyc <= slave_i.cyc or s_tx_send_now;
  s_slave_i.stb <= slave_i.stb and (slave_i.adr(c_dat_bit) or s_tx_send_now);  
  s_slave_i.we  <= slave_i.adr(c_rw_bit); 
  s_slave_i.adr <= s_adr_hi(s_adr_hi'left downto s_adr_hi'length-g_adr_bits_hi) & slave_i.adr(slave_i.adr'left-g_adr_bits_hi downto 0); 

  framer: eb_framer 
   PORT MAP (
         
		  clk_i           => clk_i,
		  rst_n_i         => s_rst_n,
      slave_i  			  => s_slave_i,
			slave_stall_o	  => s_stall,
			tx_send_now_i   => s_tx_send_now,
      master_o        => s_framer2narrow,
      master_i        => s_narrow2framer,
      tx_flush_o      => s_tx_flush, 
      max_ops_i       => s_max_ops,
      length_i        => s_length,
      cfg_rec_hdr_i		=> s_cfg_rec_hdr
			);  




 
narrow : eb_stream_narrow
    generic map(
      g_slave_width  => 32,
      g_master_width => 16)
    port map(
      clk_i    => clk_i,
      rst_n_i  => s_rst_n,
      slave_i  => s_framer2narrow,
      slave_o  => s_narrow2framer,
      master_i => s_tx2narrow,
      master_o => s_narrow2tx);

      

  tx : eb_eth_tx
    generic map(
      g_mtu => 1500)
    port map(
      clk_i        => clk_i,
      rst_n_i      => s_rst_n,
      src_i        => src_i,
      src_o        => src_o,
      slave_o      => s_tx2narrow,
      slave_i      => s_narrow2tx,
      stb_i        => s_tx_stb,
      stall_o      => s_tx_stall,
      mac_i        => s_his_mac,
      ip_i         => s_his_ip,
      port_i       => s_his_port,
      length_i     => s_length,
      skip_stb_i   => s_skip_stb,
      skip_stall_o => s_skip_stall,
      my_mac_i     => s_my_mac,
      my_ip_i      => s_my_ip,
      my_port_i    => s_my_port);

p_main : process (clk_i, rst_n_i) is

begin
	if rst_n_i = '0' then

	elsif rising_edge(clk_i) then

  end if;

end process;

end architecture;
