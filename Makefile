IVERILOG ?= iverilog
VVP ?= vvp

RTL := $(sort $(wildcard src/*.v))
BUILD_DIR := build

TESTS := \
	test-sccb_sequencer \
	test-line_buffer \
	test-ov7670_capture \
	test-stream_edge \
	test-frame_buffer_bram \
	test-agv_top

.PHONY: all test clean $(TESTS)

all: $(TESTS)

test: all

define RUN_TEST
$1:
	@command -v $(IVERILOG) >/dev/null 2>&1 || { echo "Error: $(IVERILOG) is not installed."; exit 1; }
	@command -v $(VVP) >/dev/null 2>&1 || { echo "Error: $(VVP) is not installed."; exit 1; }
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -s $2 -o $(BUILD_DIR)/$1.vvp $(RTL) $3
	$(VVP) $(BUILD_DIR)/$1.vvp
endef

$(eval $(call RUN_TEST,test-sccb_sequencer,tb_sccb_sequencer,tb/tb_sccb_sequencer.v))
$(eval $(call RUN_TEST,test-line_buffer,tb,tb/tb_line_buffer.v))
$(eval $(call RUN_TEST,test-ov7670_capture,tb,tb/tb_ov7670_capture.v))
$(eval $(call RUN_TEST,test-stream_edge,tb,tb/tb_stream_edge.v))
$(eval $(call RUN_TEST,test-frame_buffer_bram,tb_frame_buffer_bram,tb/tb_frame_buffer_bram.v))
$(eval $(call RUN_TEST,test-agv_top,tb_agv_top,tb/tb_agv_top.v))

clean:
	rm -rf $(BUILD_DIR)