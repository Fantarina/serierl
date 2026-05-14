/**
 * serierl_port.c
 * License: Apache 2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <poll.h>
#include <sys/ioctl.h>

typedef unsigned char byte;

// Global serial file descriptor
int serial_fd = -1;

// --- Erlang Port I/O Helpers ---

int read_exact(byte *buf, int len) {
    int i, got = 0;
    do {
        if ((i = read(STDIN_FILENO, buf + got, len - got)) <= 0) return i;
        got += i;
    } while (got < len);
    return len;
}

int write_exact(byte *buf, int len) {
    int i, wrote = 0;
    do {
        if ((i = write(STDOUT_FILENO, buf + wrote, len - wrote)) <= 0) return i;
        wrote += i;
    } while (wrote < len);
    return len;
}

void send_response(byte cmd, const char *payload, int payload_len) {
    byte header[2];
    int total_len = payload_len + 1;
    header[0] = (total_len >> 8) & 0xff;
    header[1] = total_len & 0xff;
    write_exact(header, 2);
    write_exact(&cmd, 1);
    if (payload_len > 0) {
        write_exact((byte*)payload, payload_len);
    }
}

// --- Termios Handlers ---

void handle_open(byte *payload, int len) {
    if (len < 9) { send_response(1, "INV_ARGS", 8); return; }
    if (serial_fd != -1) close(serial_fd);

    uint32_t baudrate = (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
    byte bytesize     = payload[4];
    byte parity       = payload[5];
    byte stopbits     = payload[6];
    byte flow_mask    = payload[7];
    byte exclusive    = payload[8];
    char *port_name   = (char *)&payload[9];

    int flags = O_RDWR | O_NOCTTY | O_NDELAY;
    if (exclusive) flags |= O_EXCL;
    
    serial_fd = open(port_name, flags);
    if (serial_fd == -1) { send_response(1, "EOPEN", 5); return; }

    struct termios tty;
    if (tcgetattr(serial_fd, &tty) != 0) { send_response(1, "EATTR", 5); return; }

    speed_t speed;
    switch(baudrate) {
        case 4800: speed = B4800; break;
        case 9600: speed = B9600; break;
        case 19200: speed = B19200; break;
        case 38400: speed = B38400; break;
        case 57600: speed = B57600; break;
        case 115200: speed = B115200; break;
        default: speed = B9600; break; 
    }
    cfsetospeed(&tty, speed);
    cfsetispeed(&tty, speed);

    tty.c_cflag &= ~CSIZE;
    switch(bytesize) {
        case 5: tty.c_cflag |= CS5; break;
        case 6: tty.c_cflag |= CS6; break;
        case 7: tty.c_cflag |= CS7; break;
        case 8: default: tty.c_cflag |= CS8; break;
    }

    tty.c_cflag &= ~(PARENB | PARODD);
    #ifndef CMSPAR
    #define CMSPAR 010000000000
    #endif
    
    if (parity == 1)      { tty.c_cflag |= PARENB | PARODD; }
    else if (parity == 2) { tty.c_cflag |= PARENB; }
    else if (parity == 3) { tty.c_cflag |= PARENB | CMSPAR | PARODD; } 
    else if (parity == 4) { tty.c_cflag |= PARENB | CMSPAR; }       

    if (stopbits == 2) { tty.c_cflag |= CSTOPB; }
    else { tty.c_cflag &= ~CSTOPB; }

    int xonxoff = flow_mask & 0x01;
    int rtscts  = (flow_mask >> 1) & 0x01;

    if (xonxoff) { tty.c_iflag |= (IXON | IXOFF | IXANY); }
    else         { tty.c_iflag &= ~(IXON | IXOFF | IXANY); }

    if (rtscts)  { tty.c_cflag |= CRTSCTS; }
    else         { tty.c_cflag &= ~CRTSCTS; }

    tty.c_cflag |= (CLOCAL | CREAD);
    tty.c_lflag &= ~(ICANON | ECHO | ECHOE | ISIG);
    tty.c_oflag &= ~OPOST;

    tcsetattr(serial_fd, TCSANOW, &tty);
    send_response(0, NULL, 0);
}

void handle_set_modem(byte *payload, int len) {
    if (serial_fd == -1) { send_response(1, "NOT_OPEN", 8); return; }
    int status;
    if (ioctl(serial_fd, TIOCMGET, &status) == -1) {
        send_response(1, "EIOCTL", 6); return;
    }
    
    if (payload[0] == 0) { 
        if (payload[1]) status |= TIOCM_RTS; else status &= ~TIOCM_RTS;
    } else { 
        if (payload[1]) status |= TIOCM_DTR; else status &= ~TIOCM_DTR;
    }
    
    if (ioctl(serial_fd, TIOCMSET, &status) == -1) {
        send_response(1, "EIOCTL", 6); return;
    }
    send_response(0, NULL, 0);
}

void handle_buffer_ops(byte *payload, int len) {
    if (serial_fd == -1) { send_response(1, "NOT_OPEN", 8); return; }
    
    if (payload[0] == 1) tcflush(serial_fd, TCIFLUSH);
    else if (payload[0] == 2) tcflush(serial_fd, TCOFLUSH);
    else if (payload[0] == 3) tcflush(serial_fd, TCIOFLUSH);
    else if (payload[0] == 4) tcdrain(serial_fd); 
    
    send_response(0, NULL, 0);
}

void handle_get_signals(byte *payload, int len) {
    if (serial_fd == -1) { send_response(1, "NOT_OPEN", 8); return; }
    int status;
    if (ioctl(serial_fd, TIOCMGET, &status) == -1) {
        send_response(1, "EIOCTL", 6); return;
    }
    
    byte mask = 0;
    if (status & TIOCM_CTS) mask |= (1 << 0);
    if (status & TIOCM_DSR) mask |= (1 << 1);
    if (status & TIOCM_RI)  mask |= (1 << 2);
    if (status & TIOCM_CD)  mask |= (1 << 3);
    
    send_response(0, (char *)&mask, 1);
}

// --- Main Event Loop ---

int main() {
    struct pollfd fds[2];
    byte header[2];
    byte buffer[4096];

    while (1) {
        fds[0].fd = STDIN_FILENO;
        fds[0].events = POLLIN;

        fds[1].fd = serial_fd;
        fds[1].events = (serial_fd != -1) ? POLLIN : 0;

        int ret = poll(fds, 2, -1);
        if (ret < 0) continue;

        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            if (read_exact(header, 2) != 2) break; 
            
            int len = (header[0] << 8) | header[1];
            if (read_exact(buffer, len) != len) break;

            byte cmd = buffer[0];
            byte *payload = buffer + 1;
            int payload_len = len - 1;

            switch(cmd) {
                case 1: handle_open(payload, payload_len); break;
                case 2: 
                    if (serial_fd != -1) {
                        int _res = write(serial_fd, payload, payload_len);
                        (void)_res; 
                    }
                    break;
                case 3: 
                    if (serial_fd != -1) { close(serial_fd); serial_fd = -1; }
                    send_response(0, NULL, 0);
                    break;
                case 4: handle_set_modem(payload, payload_len); break;
                case 5: handle_buffer_ops(payload, payload_len); break;
                case 6: handle_get_signals(payload, payload_len); break;
            }
        }

        if (serial_fd != -1 && (fds[1].revents & (POLLIN | POLLERR))) {
            int bytes_read = read(serial_fd, buffer, sizeof(buffer));
            if (bytes_read > 0) {
                send_response(2, (char*)buffer, bytes_read);
            } else if (bytes_read <= 0) {
                close(serial_fd);
                serial_fd = -1;
            }
        }
    }
    return 0;
}