# c_src/Makefile

# The directory where the compiled binary will be stored
PRIV_DIR = ../priv

# The name of the compiled executable
EXE = $(PRIV_DIR)/serierl_port

# The C source files
SRC = serierl_port.c

# Standard compiler flags for optimization and warnings
CFLAGS ?= -O2 -Wall -Wextra

.PHONY: all clean

all: $(PRIV_DIR) $(EXE)

# Ensure the priv directory exists before compiling
$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

# Compile the C source into the target executable
$(EXE): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

# Clean up the compiled binary
clean:
	rm -f $(EXE)