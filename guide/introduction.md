# Understanding Serial Communication & Serierl

This guide explains the fundamentals of serial communication, how the hardware operates, and how the `serierl` application processes data between the Erlang Virtual Machine and external hardware devices.

---

## 1. What is a Serial Device?

A serial device uses a communication interface that transmits data sequentially, exactly one bit at a time, over a single communication channel or wire. This contrasts with parallel communication, where multiple bits are sent simultaneously over multiple wires.

Modern serial devices typically use the **UART** (Universal Asynchronous Receiver-Transmitter) hardware protocol. "Asynchronous" means there is no shared clock signal wire between the sender and receiver. Instead, both devices must be configured to the exact same timing parameters (baud rate) to understand where one bit ends and the next begins.

Common examples of serial devices include:
*   **Embedded Systems:** Microcontrollers (Arduino, ESP32, Raspberry Pi UART).
*   **Industrial Equipment:** PLCs, motor controllers, and sensor networks (often using RS-232, RS-485, or Modbus protocols).
*   **Telecommunications:** Cellular modems (GSM/LTE/5G) controlled via AT commands.
*   **USB Adapters:** Devices like FTDI chips that convert a modern USB connection into a legacy hardware UART interface (appearing as `/dev/ttyUSB0` or `COM3`).

---

## 2. The Serierl Process Flow

To guarantee the stability of the Erlang Virtual Machine (BEAM), `serierl` strictly isolates hardware operations from Erlang processes. Physical hardware is unpredictable; USB cables can be unplugged during transmission, and OS-level drivers can hang. 

`serierl` handles this using a split architecture:

1.  **The Erlang `gen_server` (`serierl.erl`):** 
    This is the interface your application interacts with. It maintains an internal memory buffer, handles pattern-matching for specific byte sequences (like `read_until`), and manages timeout timers using Erlang's native messaging system.
2.  **The OS Pipe (Erlang Port):**
    The `gen_server` communicates with a separate OS process via standard standard streams (stdin/stdout). This acts as a firewall. 
3.  **The C Binary (`serierl_port.c`):**
    This is a lightweight, asynchronous C program running directly on the host operating system. It uses `poll()` to monitor the physical hardware non-blockingly. It maps Erlang's commands directly to Linux POSIX `termios` API calls.
4.  **The Hardware Device (`/dev/tty*`):**
    The physical hardware driver translates the `termios` configurations into actual voltage changes on the transmission wire.

**Fault Tolerance:** If the physical serial device suffers a catastrophic failure or the OS driver segfaults, only the isolated C binary crashes. The Erlang VM detects the closed pipe, the `gen_server` shuts down cleanly, and the OTP Supervisor can log the error without affecting the rest of your system.

---

## 3. Configuration Options (`serial_options`)

Because asynchronous serial communication lacks a shared clock, both the Erlang application and the physical hardware must agree on the exact structure of the data frames. 

Here is what each configuration option dictates at the hardware level:

### Timing and Framing
*   **`baudrate`** (e.g., `9600`, `115200`): The speed of transmission, measured in bits per second. This dictates the precise microsecond duration that the hardware will hold a voltage on the wire to represent a `1` or a `0`. If the sender and receiver have mismatched baud rates, the data will be read as garbage.
*   **`bytesize`** (e.g., `8`, `7`): The number of data bits in a single frame. The modern standard is `8` (one complete byte). Older industrial systems may use `7` or `5`.
*   **`stopbits`** (e.g., `1`, `2`): The mandatory idle time at the end of a frame. `1` means the line rests for the duration of one bit before the next frame can start. `2` doubles this rest period, giving slower hardware more time to process the received byte.

### Error Checking
*   **`parity`** (`none`, `even`, `odd`, `mark`, `space`): A primitive hardware-level error-checking mechanism. If set to `even` or `odd`, the UART hardware appends an extra bit to the frame to ensure the total number of `1` bits is always even or odd. If interference flips a bit on the wire, the receiver's hardware calculates a parity mismatch and silently discards the corrupted byte. `none` disables this feature.

### Flow Control
If a sender transmits data faster than a receiver can process it, internal hardware buffers will overflow, and data will be dropped. Flow control prevents this by allowing the receiver to signal the sender to pause.
*   **`xonxoff`** (Software Flow Control): Uses in-band data. The receiver sends special ASCII characters (`XOFF` / 0x13) to pause transmission and (`XON` / 0x11) to resume. It requires no extra wiring, but binary data payloads cannot contain the 0x11 or 0x13 bytes, or they will accidentally trigger flow control.
*   **`rtscts`** (Hardware Flow Control): Uses dedicated physical wires (RTS: Request To Send, CTS: Clear To Send). When the receiver's buffer is full, it drops the voltage on the CTS line, instantly pausing the sender at the hardware level. This is highly reliable for fast, binary data transfers.
*   **`dsrdtr`**: Similar to `rtscts`, but uses the DTR (Data Terminal Ready) and DSR (Data Set Ready) pins. Often used to signal if a device is physically powered on and connected.

### OS Management
*   **`exclusive`** (Boolean): When `true`, requests the operating system to apply a lock on the `/dev/` file descriptor. This prevents other OS processes (like a rogue Python script or a terminal emulator) from accidentally opening the same port and intercepting your data.
*   **`drop_reads`** (Boolean): An Erlang-specific optimization. When `true`, the Erlang `gen_server` actively discards all incoming data from the device. This is useful for memory management if you are only sending commands to a device (like a basic actuator) and do not care about its telemetry responses.