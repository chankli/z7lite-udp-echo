SIM ?= vsim
TEST ?= all
WORK = work

CUSTOM_RTL = ../../rtl
VETH = ../../vendor/verilog-ethernet
SRC = \
  $(CUSTOM_RTL)/udp_axis_complete.v \
  $(CUSTOM_RTL)/icmp_echo.v \
  $(VETH)/rtl/eth_axis_rx.v \
  $(VETH)/rtl/eth_axis_tx.v \
  $(VETH)/rtl/udp_complete.v \
  $(VETH)/rtl/udp.v \
  $(VETH)/rtl/udp_ip_rx.v \
  $(VETH)/rtl/udp_ip_tx.v \
  $(VETH)/rtl/udp_checksum_gen.v \
  $(VETH)/rtl/ip_complete.v \
  $(VETH)/rtl/ip.v \
  $(VETH)/rtl/ip_eth_rx.v \
  $(VETH)/rtl/ip_eth_tx.v \
  $(VETH)/rtl/ip_arb_mux.v \
  $(VETH)/rtl/arp.v \
  $(VETH)/rtl/arp_cache.v \
  $(VETH)/rtl/arp_eth_rx.v \
  $(VETH)/rtl/arp_eth_tx.v \
  $(VETH)/rtl/lfsr.v \
  $(VETH)/rtl/eth_arb_mux.v \
  $(VETH)/lib/axis/rtl/axis_fifo.v \
  $(VETH)/lib/axis/rtl/axis_srl_fifo.v \
  $(VETH)/lib/axis/rtl/axis_async_fifo.v \
  $(VETH)/lib/axis/rtl/axis_async_fifo_adapter.v \
  $(VETH)/lib/axis/rtl/arbiter.v \
  $(VETH)/lib/axis/rtl/priority_encoder.v \
  $(VETH)/lib/axis/rtl/sync_reset.v

.PHONY: sim clean

sim:
	vlib $(WORK)
	vlog -work $(WORK) $(SRC)
	vlog -sv -work $(WORK) tb_udp_axis_complete.sv
	$(SIM) -c -work $(WORK) tb_udp_axis_complete +TEST=$(TEST) -do "run -all; quit -f"

clean:
	rm -rf $(WORK) transcript vsim.wlf
