#!/bin/bash

# This script reads a file named 'panel.txt' and extracts
# and formats network port and IP address information.

# Check if the panel.txt file exists. If not, exit with an error.
if [ ! -f "panel.txt" ]; then
    echo "Error: The file 'panel.txt' was not found in the current directory."
    exit 1
fi

# Clear the contents of the output files to start fresh.
> tcp4_in.txt
> tcp4_out.txt
> tcp6_in.txt
> tcp6_out.txt
> ipv4.txt
> ipv6.txt

# Read the file 'panel.txt' line by line.
while IFS= read -r line || [[ -n "$line" ]]; do
    # Remove leading and trailing whitespace from the line.
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Check the variable name on the line.
    case "$line" in
        TCP_IN*)
            # Extract port numbers, separate by newline, and add 'T' suffix.
            ports=$(echo "$line" | cut -d'"' -f2 | tr ',' '\n')
            for port in $ports; do
                echo "${port}T" >> tcp4_in.txt
            done
            ;;
        TCP_OUT*)
            ports=$(echo "$line" | cut -d'"' -f2 | tr ',' '\n')
            for port in $ports; do
                echo "${port}T" >> tcp4_out.txt
            done
            ;;
        TCP6_IN*)
            ports=$(echo "$line" | cut -d'"' -f2 | tr ',' '\n')
            for port in $ports; do
                echo "${port}T" >> tcp6_in.txt
            done
            ;;
        TCP6_OUT*)
            ports=$(echo "$line" | cut -d'"' -f2 | tr ',' '\n')
            for port in $ports; do
                echo "${port}T" >> tcp6_out.txt
            done
            ;;
        IP_ADDRESS*)
            # Extract IP addresses.
            ips=$(echo "$line" | cut -d'"' -f2 | tr ',' '\n')
            for ip in $ips; do
                # Check if the IP address contains a colon, which indicates IPv6.
                if [[ "$ip" == *":"* ]]; then
                    echo "$ip" >> ipv6.txt
                elif [[ -n "$ip" ]]; then
                    # Assumes anything else is IPv4 and not empty.
                    echo "$ip" >> ipv4.txt
                fi
            done
            ;;
        *)
            # Ignore other lines.
            ;;
    esac
done < "panel.txt"

echo "Processing complete. Check the output files:"
echo "  - tcp4_in.txt"
echo "  - tcp4_out.txt"
echo "  - tcp6_in.txt"
echo "  - tcp6_out.txt"
echo "  - ipv4.txt"
echo "  - ipv6.txt"
