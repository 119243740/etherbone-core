library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.wishbone_pkg.all;
use work.wr_fabric_pkg.all;
use work.eb_internals_pkg.all;
use work.eb_hdr_pkg.all;

entity eb_master_eth_tx is
  generic(
    g_mtu : natural);
  port(
    clk_i        : in  std_logic;
    rst_n_i      : in  std_logic;
    src_i        : in  t_wrf_source_in;
    src_o        : out t_wrf_source_out;
    slave_o      : out t_wishbone_slave_out;
    slave_i      : in  t_wishbone_slave_in;
    stb_i        : in  std_logic;
    stall_o      : out std_logic;
    mac_i        : in  std_logic_vector(47 downto 0);
    ip_i         : in  std_logic_vector(31 downto 0);
    port_i       : in  std_logic_vector(15 downto 0);
    skip_stb_i   : in  std_logic;
    skip_stall_o : out std_logic;
    --fifo_cnt_o   : out std_logic(f_ceil_log2( (g_mtu+c_eth_len)/2 ) downto 0); 
    my_mac_i     : in  std_logic_vector(47 downto 0);
    my_ip_i      : in  std_logic_vector(31 downto 0);
    my_port_i    : in  std_logic_vector(15 downto 0);
    use_fec_i    : in  std_logic := '0'
  );
end eb_master_eth_tx;

architecture rtl of eb_master_eth_tx is
  type t_state is (S_WRF_STATUS, S_ETHERNET, S_IP, S_UDP, S_DONE, S_WAIT, S_PAYLOAD, S_RUNT, S_LOWER, S_SKIP, S_PUSH);
  type t_sum_state is (S_CONST, S_DST_HI, S_DST_LO, S_SRC_HI, S_SRC_LO, S_DONE);
  
  signal r_state  : t_state;
  signal r_staten : t_state;
  signal r_count  : unsigned(4 downto 0);
  
  signal r_ready  : std_logic;
  signal r_mac    : std_logic_vector(47 downto 0);
  signal r_ip     : std_logic_vector(31 downto 0);
  signal r_port   : std_logic_vector(15 downto 0);
  signal r_length : unsigned(15 downto 0);

  signal r_hdr_stb : std_logic;
  signal r_shift   : std_logic_vector(c_ip_len*8-1 downto 0);
  signal r_ack     : std_logic;
  signal s_stall   : std_logic;
  
  signal s_buf_stb    : std_logic;
  signal s_buf_full   : std_logic;
  signal s_buf_push   : std_logic;
  signal s_buf_commit : std_logic;
  signal s_buf_abort  : std_logic;
  signal s_buf_cyc    : std_logic;
  signal s_buf_data   : std_logic_vector(15 downto 0);
  signal r_buf_typ    : std_logic;
  
  signal r_tx_cyc   : std_logic;
  signal s_tx_empty : std_logic;
  signal s_tx_pop   : std_logic;
  signal s_tx_cyc   : std_logic;
  signal s_tx_typ   : std_logic;
  signal s_tx_dat   : std_logic_vector(15 downto 0);
  
  signal r_sum_state : t_sum_state;
  signal r_sum_en    : std_logic;
  signal r_sum_data  : std_logic_vector(15 downto 0);
  signal s_sum_done  : std_logic_vector(15 downto 0);
  
  constant c_ip_tol_pos       : natural := 2;
  constant c_ip_chk_pos       : natural := 10;
  constant c_udp_len_pos      : natural := 4;
  constant c_eth_typ_len_pos  : natural := 12;
  signal s_tx_out_cnt,
         s_tx_in_cnt      : unsigned(f_ceil_log2( (g_mtu+c_eth_len)/2 ) downto 0);
  signal s_tx_stb,
         s_ip_tol_ins,
         s_ip_chk_ins,
         s_eth_typ_len_ins,
         s_udp_len_ins    : std_logic;
  signal s_otf_mux        : std_logic_vector(3 downto 0);
  signal s_ip_chk         : std_logic_vector(15 downto 0);
  signal r_ip_tol,
         r_udp_len,
         r_eth_typ_len    : std_logic_vector(15 downto 0);
  
  signal r_output_cnt,
         r_debug_exp      : unsigned(15 downto 0);
  signal s_src_cyc,
         s_src_stb,
         r_src_cyc        : std_logic;


  constant c_hdr_len  : natural := c_ip_len;
  constant c_runt_min : natural := 64;
  
  function f_send_eth(dst, src : std_logic_vector(47 downto 0)) return std_logic_vector is
    variable o : std_logic_vector(c_hdr_len*8-1 downto 0) := (others => '-');
    variable eth : t_eth_hdr := c_eth_init;
  begin
    eth.dst := dst;
    eth.src := src;
    o(o'left downto (c_hdr_len-c_eth_len)*8) := f_format_eth(eth);
    return o;
  end function;
  
  function f_send_ip(dst, src : std_logic_vector(31 downto 0); len : unsigned(15 downto 0); sum : std_logic_vector(15 downto 0)) return std_logic_vector is
    variable o : std_logic_vector(c_hdr_len*8-1 downto 0) := (others => '-');
    variable ip : t_ip_hdr := c_ip_init;
  begin
    ip.tol := std_logic_vector(len+20);
    ip.dst := dst;
    ip.src := src;
    ip.sum := not sum;
    o(o'left downto (c_hdr_len-c_ip_len)*8) := f_format_ip(ip);
    return o;
  end function;
  
  function f_send_udp(dst, src : std_logic_vector(15 downto 0); len : unsigned(15 downto 0)) return std_logic_vector is
    variable o : std_logic_vector(c_hdr_len*8-1 downto 0) := (others => '-');
    variable udp : t_udp_hdr := c_udp_init;
  begin
    udp.src := src;
    udp.dst := dst;
    udp.len := (others => '0');
    o(o'left downto (c_hdr_len-c_udp_len)*8) := f_format_udp(udp);
    return o;
  end function;
  
  function f_step(x : natural) return unsigned is
  begin
    return to_unsigned(x/2 - 1, 5);
  end function;
  
begin

  tx : eb_commit_len_fifo
    generic map(
      g_width => 18,
      g_size  => (g_mtu+c_eth_len)/2)
    port map(
      clk_i      => clk_i,
      rstn_i     => rst_n_i,
      w_full_o   => s_buf_full,
      w_push_i   => s_buf_push,
      w_commit_i => s_buf_commit,
      w_abort_i  => s_buf_abort,
      r_empty_o  => s_tx_empty,
      r_cnt_o    => s_tx_out_cnt,
      w_cnt_o    => s_tx_in_cnt,
      r_pop_i    => s_tx_pop,
      w_dat_i(17)          => s_buf_cyc,
      w_dat_i(16)          => r_buf_typ,
      w_dat_i(15 downto 0) => s_buf_data,
      r_dat_o(17)          => s_tx_cyc,
      r_dat_o(16)          => s_tx_typ,
      r_dat_o(15 downto 0) => s_tx_dat);
  
  slave_o.ack <= r_ack;
  slave_o.int <= '0';
  slave_o.rty <= '0';
  slave_o.err <= '0';
  slave_o.stall <= s_stall;
  slave_o.dat <= (others => '0');
  
  stall_o <= r_ready; -- already have params
  
  s_stall      <= s_buf_full when r_state=S_PAYLOAD else '1';
  skip_stall_o <= '0' when r_state=S_SKIP else '1';
  s_buf_stb    <= (slave_i.cyc and slave_i.stb) when r_state=S_PAYLOAD else r_hdr_stb;
  s_buf_push   <= s_buf_stb and not s_buf_full;
  s_buf_abort  <= '1' when r_state=S_SKIP  else '0';
  s_buf_commit <= '1' when r_state=S_LOWER else '0';
  s_buf_cyc    <= '0' when r_state=S_LOWER else '1';
  s_buf_data   <= slave_i.dat(15 downto 0) when r_state=S_PAYLOAD else r_shift(r_shift'left downto r_shift'left-15);
  
  hdr : process(clk_i, rst_n_i) is
  begin
    if rst_n_i = '0' then
      r_state   <= S_WRF_STATUS;
      r_staten  <= S_WRF_STATUS;
      r_count   <= (others => '0');
      r_ready   <= '0';
      r_mac     <= (others => '0');
      r_ip      <= (others => '0');
      r_port    <= (others => '0');
      r_length  <= (others => '0');
      r_hdr_stb <= '0';
      r_ack     <= '0';
      r_shift   <= (others => '-');
      r_tx_cyc  <= '0';
    elsif rising_edge(clk_i) then
      r_ack <= slave_i.cyc and slave_i.stb and not s_stall;
      
      if s_tx_empty = '0' then
        r_tx_cyc <= s_tx_cyc;
            else
        r_tx_cyc <= '0'; 
      end if;
      
      if stb_i = '1' and r_ready = '0' then
        r_mac    <= mac_i;
        r_ip     <= ip_i;
        r_port   <= port_i;
        r_ready  <= '1';
      end if;
      
      case r_state is
        when S_WRF_STATUS =>
          if r_ready = '1' then
            r_hdr_stb <= '1';
            r_buf_typ <= '1';
            r_shift   <= (others => '0');
            r_state   <= S_ETHERNET;
          end if;
        
        when S_ETHERNET =>
          if s_buf_full = '0' then
            r_buf_typ <= '0';
            r_shift   <= f_send_eth(r_mac, my_mac_i);
            r_count   <= f_step(c_eth_len);
            r_staten  <= S_IP;
            r_state   <= S_PUSH;
          end if;
          
        when S_IP =>
          if s_buf_full = '0' then
            r_shift <= f_send_ip(r_ip, my_ip_i, x"0000", s_sum_done);
            r_count <= f_step(c_ip_len);
            r_staten <= S_UDP;
            r_state  <= S_PUSH;
          end if;
        
        when S_UDP =>
          if s_buf_full = '0' then
            r_shift  <= f_send_udp(r_port, my_port_i, x"0000");
            r_count  <= f_step(c_udp_len);
            r_staten <= S_DONE;
            r_state  <= S_PUSH;
          end if;
        
        when S_DONE =>
          if s_buf_full = '0' then
            r_ready   <= '0'; -- can latch next header params
            r_hdr_stb <= '0'; -- nothing more from the header side of things
            
            -- After payload, may need to add runt padding
            r_shift <= (others => '0');
            
 
            
            -- Make sure we don't skip the payload!
            if slave_i.cyc = '1' then
              r_state <= S_PAYLOAD;
            elsif skip_stb_i = '1' then
              r_state <= S_SKIP;
            else
              r_state <= S_WAIT;
            end if;
          end if;
          
        when S_WAIT =>
          if slave_i.cyc = '1' then
            r_state <= S_PAYLOAD;
          elsif skip_stb_i = '1' then
            r_state <= S_SKIP;
          end if;
        
        when S_PAYLOAD =>
          if to_integer(s_tx_in_cnt -2) < c_runt_min then
            r_staten <= S_RUNT;
            r_count <= f_step(c_runt_min - to_integer(s_tx_in_cnt -2));
          else
            r_staten <= S_LOWER;
            r_count <= (others => '-');
          end if;

          if slave_i.cyc = '0' then
            r_hdr_stb <= '1';
            r_state <= r_staten;
          end if;
        
        when S_RUNT =>
          if s_buf_full = '0' then
            r_state   <= S_PUSH;
            r_staten  <= S_LOWER;
          end if;
        
        when S_LOWER =>
          if s_buf_full = '0' then
            r_hdr_stb <= '0';
            r_state <= S_WRF_STATUS;
          end if;
        
        when S_SKIP =>
          r_state <= S_WRF_STATUS;
        
        when S_PUSH =>
          if s_buf_full = '0' then
            r_count <= r_count - 1;
            r_shift <= r_shift(r_shift'left-16 downto 0) & x"0000";
            
            if r_count = to_unsigned(1, r_count'length) then
              r_state <= r_staten;
            end if;
          end if;
          
      end case;
    end if;
  end process;

  s_src_cyc <= s_tx_cyc when s_tx_empty='0' else r_tx_cyc;
  s_src_stb <= not s_tx_empty and s_tx_stb; 


  src_o.cyc <= s_src_cyc;
  src_o.stb <= s_src_stb;
  src_o.adr <= c_WRF_STATUS when s_tx_typ='1' else c_WRF_DATA;
  src_o.we  <= '1';
  src_o.sel <= "11";

--**************************************************************************--
-- on the fly insertion of IP TOL and IP Checksum field
------------------------------------------------------------------------------
  -- use FIFO cyc output this to control WB cycle line
  s_tx_stb <= s_tx_cyc;

  -- Flag for Ethertype Length field, high when present on s_tx_dat 
  s_eth_typ_len_ins <= '1' when ((r_output_cnt  = c_eth_typ_len_pos) AND use_fec_i = '1')
             else '0';

  
  -- Flag for TOL field, high when present on s_tx_dat 
  s_ip_tol_ins <= '1' when r_output_cnt   = (c_eth_len + c_ip_tol_pos)
             else '0';
  
  -- Flag for Checksum field, high when present on s_tx_dat            
  s_ip_chk_ins <= '1' when r_output_cnt = (c_eth_len + c_ip_chk_pos)
             else '0';
             
  -- Flag for TOL field, high when present on s_tx_dat 
  s_udp_len_ins <= '1' when r_output_cnt = (c_eth_len + c_ip_len + c_udp_len_pos)
             else '0';                      
  
  -- Correct checksum including TOL, valid on s_ip_chk_ins HI
  s_ip_chk <= not(std_logic_vector(unsigned(s_tx_dat) + unsigned(r_ip_tol)));
  
  -- Output Mux for otf insertion
  s_otf_mux <= s_udp_len_ins & s_ip_chk_ins & s_ip_tol_ins & s_eth_typ_len_ins;
  
  otf_mux : with s_otf_mux select
   src_o.dat <= s_tx_dat      when "0000",
                r_eth_typ_len when "0001",
                r_ip_tol      when "0010",
                s_ip_chk      when "0100",
                r_udp_len     when "1000",
                s_tx_dat      when others;  
  

  
  -- get TOL from first element in commit fifo
   otf_mod_ip_hdr : process(clk_i)
   begin
      if rising_edge(clk_i) then
         if ( s_tx_typ = '0' and s_tx_cyc = '0' and s_tx_empty = '0') then -- only first element (length) in commit fifo is type 0 cyc 0
             r_ip_tol <=  std_logic_vector(unsigned(s_tx_dat) - to_unsigned(c_eth_len, s_tx_dat'length) -2); -- deduct eth hdr length and OOB length element
             r_udp_len <= std_logic_vector(unsigned(s_tx_dat) - to_unsigned(c_eth_len + c_ip_len, s_tx_dat'length) -2);
             r_eth_typ_len  <= std_logic_vector(unsigned(s_tx_dat) - to_unsigned(c_eth_len, s_tx_dat'length) - 2);
         end if;

      end if;   
   end process;




  output_cnt :  process(clk_i, rst_n_i) is
  begin
    if rst_n_i = '0' then
      r_output_cnt  <= (others => '0');
      r_debug_exp   <= (others => '0');
      r_src_cyc     <= '0';
    elsif rising_edge(clk_i) then

      if( s_tx_typ = '0' and s_tx_cyc = '0' and s_tx_empty = '0')  then
             r_debug_exp <=  unsigned(s_tx_dat) -2; -- deduct eth hdr length and OOB length element
      end if;

      r_src_cyc <= s_src_cyc;



      if (s_src_cyc and s_src_stb and not s_tx_typ and not src_i.stall) = '1' then
        r_output_cnt <= r_output_cnt +2;
      end if;


      if s_src_cyc = '0' and r_src_cyc = '1' then
        assert r_output_cnt = r_debug_exp report "COUNTER MISMATCH!!!" severity failure; 
        r_output_cnt <= (others => '0');
      end if;
  end if;
  end process;

------------------------------------------------------------------------------

  s_tx_pop <= not s_tx_empty and not (s_tx_cyc and src_i.stall);
  
  sum : eb_checksum
    port map(
      clk_i => clk_i,
      nRst_i => rst_n_i,
      en_i   => r_sum_en,
      data_i => r_sum_data,
      done_o => open,
      sum_o  => s_sum_done);
  
  sum_header : process(clk_i, rst_n_i) is
  begin
    if rst_n_i = '0' then
      r_sum_state <= S_CONST;
      r_sum_en    <= '0';
      r_sum_data  <= (others => '0');
    elsif rising_edge(clk_i) then
    
      case r_sum_state is
        when S_CONST =>
          r_sum_data <= f_checksum(f_format_ip(c_ip_init));
          if stb_i = '1' and r_ready = '0' then
            r_sum_en    <= '1';
            r_sum_state <= S_DST_HI;
          end if;
        
        when S_DST_HI => r_sum_state <= S_DST_LO; r_sum_data <=    r_ip(31 downto 16);
        when S_DST_LO => r_sum_state <= S_SRC_HI; r_sum_data <=    r_ip(15 downto  0);
        when S_SRC_HI => r_sum_state <= S_SRC_LO; r_sum_data <= my_ip_i(31 downto 16);
        when S_SRC_LO => r_sum_state <= S_DONE;   r_sum_data <= my_ip_i(15 downto  0);
        --when S_LENGTH => r_sum_state <= S_DONE;   r_sum_data <= std_logic_vector(r_length+20);
        when S_DONE   => r_sum_state <= S_CONST;  r_sum_en <= '0';
      end case;
      
    end if;
  end process;
  
end rtl;
