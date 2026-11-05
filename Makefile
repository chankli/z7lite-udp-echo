.PHONY: all fpga program clean tb

all: fpga

fpga:
	$(MAKE) -C fpga

program:
	$(MAKE) -C fpga program

clean:
	$(MAKE) -C fpga clean

tb:
	$(MAKE) -C tb/udp_axis_complete sim TEST=all
