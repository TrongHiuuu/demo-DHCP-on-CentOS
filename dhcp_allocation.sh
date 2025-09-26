#!/bin/bash

CONFIG_FILE="/etc/dhcp/dhcpd.conf"
SERVICE="dhcpd"
subnet=""
netmask=""
range_start=""
range_end=""
domain_name_server=""
domain_name=""
router=""
broadcast_addr=""
domain_name_addr=""
default_lease_time=""
max_lease_time=""

# ----------------- HÀM KIỂM TRA INPUT ------------------------------
is_valid_ip() {
    local ip="$1"
    local IFS=.
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    # Kiểm tra từng octet nằm trong 0..255
    read -r a b c d <<<"$ip"
    for o in "$a" "$b" "$c" "$d"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

# Hàm kiểm tra subnet là địa chỉ network hợp lệ với netmask
is_network_address() {
    local subnet="$1"

    local subnet_int=$(ip_to_int "$subnet")
    local mask_int=$(ip_to_int "$netmask")

    if (( (subnet_int & mask_int) == subnet_int )); then
        return 0
    else
        return 1
    fi
}

is_valid_subnet(){
    local ip="$1"

    # 1. Kiểm tra ip hợp lệ chưa
    if ! is_valid_ip "$ip"; then
        echo "IP không đúng định dạng"
        return 1
    fi

    # 2. Kiểm tra subnet có phù hợp với netmask chưa
    if ! is_network_address "$ip"; then
        echo "Subnet không phù hợp với netmask"
        return 1
    fi

    # 2. Kiểm tra scope đã tồn tại chưa
    if grep -q "subnet $ip netmask $netmask" "$CONFIG_FILE"; then
        echo "Subnet đã tồn tại"
        return 1
    fi
    return 0
}

ip_to_int() {
    local ip="$1"
    IFS='.' read -r a b c d <<< "$ip"
    echo $((a * 256 * 256 * 256 + b * 256 * 256 + c * 256 + d))
}

int_to_ip() {
    local int="$1"
    echo "$((int >> 24 & 255)).$((int >> 16 & 255)).$((int >> 8 & 255)).$((int & 255))"
}

is_valid_netmask() {
    local mask="$1"

    # Kiểm tra netmask có phải là 1 IP hợp lệ hay không?
    if ! is_valid_ip "$mask"; then
        return 1
    fi

    # Tách thành các octets và chuyển mỗi octets sang dạng binary
    IFS='.' read -r -a octets <<< "$mask"
    local bin_mask=""
    for octet in "${octets[@]}"; do
        bin_mask+=$(printf "%08d" $(echo "obase=2; $octet" | bc))
    done

    # Kiểm tra hợp lệ (subnet mask có dạng các bit 1 liên tiếp, sau đó là các bit 0 liên tiếp)
    if [[ ! $bin_mask =~ ^1+0*$ ]]; then
        return 1
    fi

    # Tính toán CIDR và kiểm tra xem subnet mask có hợp lệ hay không
    local cidr=${#bin_mask}
    cidr=${bin_mask//0/}
    cidr=${#cidr}
    if ((cidr == 0 || cidr == 32)); then
        return 1  # Không cho phép /0 hoặc /32 cho DHCP subnet điển hình
    fi
    return 0
}

calculate_broadcast() {
    local subnet_int=$(ip_to_int "$subnet")
    local mask_int=$(ip_to_int "$netmask")
    # Tính nghịch đảo của netmask (vd: netmasl 255.255.255.0 -> inv_mask = 0.0.0.255)
    local inv_mask=$(( (1<<32) - 1 - mask_int ))
    # Sử dụng phép OR giữa subnet và inv_mask để tìm ra broadcast
    local broadcast_int=$(( subnet_int | inv_mask ))
    int_to_ip "$broadcast_int"
}

is_ip_in_subnet() {
    local ip="$1"
    local ip_int=$(ip_to_int "$ip")
    local subnet_int=$(ip_to_int "$subnet")
    local mask_int=$(ip_to_int "$netmask")
    # Kiểm tra xem ip có nằm trong cùng subnet hay không 
    if (( (ip_int & mask_int) == subnet_int )); then
        return 0
    else
        return 1
    fi
}

is_valid_range() {
    local start="$1"
    local end="$2"

    # Kiểm tra IP hợp lệ hay không?
    if ! is_valid_ip "$start" || ! is_valid_ip "$end"; then
        echo "IP không đúng định dạng"
        return 1
    fi
    
    # Kiểm tra range có nằm trong subnet hay không?
    if ! is_ip_in_subnet "$start" || ! is_ip_in_subnet "$end"; then
        echo "IP không nằm trong subnet"
        return 1
    fi

    local start_int=$(ip_to_int "$start")
    local end_int=$(ip_to_int "$end")
    local subnet_int=$(ip_to_int "$subnet")
    local broadcast_int=$(ip_to_int "$broadcast_addr")
    
    if (( start_int <= subnet_int || end_int >= broadcast_int )); then
        echo "IP không được trùng với subnet hoặc broadcast"
        return 1
    fi

    if (( start_int >= end_int )); then
        echo "IP bắt đầu phải nhỏ hơn IP kết thúc"
        return 1
    fi

    return 0
}

is_valid_router(){
    local ip="$1"
    # 1.Kiểm tra IP hợp lệ hay không?
    if ! is_valid_ip "$ip"; then
        echo "IP không đúng định dạng"
        return 1
    fi
    
    # 2.Kiểm tra route có nằm trong subnet hay không?
    if ! is_ip_in_subnet "$ip"; then
        echo "IP không nằm trong subnet"
        return 1
    fi

    # 3.Không trùng với subnet hoặc broadcast
    if [[ "$ip" == "$subnet" || "$ip" == "$broadcast_addr" ]]; then
        echo "IP không được trùng với subnet hoặc broadcast"
        return 1
    fi

    # 4. Không nằm trong range IP cấp phát
    local start_int=$(ip_to_int "$range_start")
    local end_int=$(ip_to_int "$range_end")
    local ip_int=$(ip_to_int "$ip")
    if (( ip_int >= start_int && ip_int <= end_int )); then
        echo "IP không được nằm trong phạm vi IP cấp phát"
        return 1
    fi
    return 0
}

is_time_positive() {
    local num="$1"
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt 0 ]; then
        return 0
    else
        echo "Thời gian phải là số dương"
        return 1
    fi
}

is_valid_domain_name_addr(){
    local ip="$1"

    # 1.Kiểm tra IP đúng định dạng hay không?
    if ! is_valid_ip "$ip"; then
        echo "IP không đúng định dạng"
        return 1
    fi
    

    # 2.Không trùng với subnet hoặc broadcast
    if [[ "$ip" == "$subnet" || "$ip" == "$broadcast_addr" ]]; then
        echo "IP không được trùng với subnet hoặc broadcast"
        return 1
    fi

    # 3. Không nằm trong range IP cấp phát
    local start_int=$(ip_to_int "$range_start")
    local end_int=$(ip_to_int "$range_end")
    local ip_int=$(ip_to_int "$ip")
    if (( ip_int >= start_int && ip_int <= end_int )); then
        echo "IP không được nằm trong phạm vi IP cấp phát"
        return 1
    fi
    return 0
}

#TrongHiuuu 19/9/2025 - Validate MAC address
is_valid_host_name() {
    local name="$1"

    # regex: chỉ cho phép chữ cái, số, dấu gạch ngang
    if [[ ! "$name" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo "Tên host chỉ được chứa chữ cái, số, dấu gạch ngang."
        return 1
    fi

    # kiểm tra trùng trong file dhcpd.conf
    if grep -q "host[[:space:]]\+$name[[:space:]]*{" "$CONFIG_FILE"; then
        echo "Tên host '$name' đã tồn tại."
        return 1
    fi

    return 0
}

is_valid_mac() {
    local mac="$1"

    # regex kiểm tra định dạng hợp lệ
    if [[ ! "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        echo "Địa chỉ MAC không hợp lệ."
        return 1
    fi

    # kiểm tra trùng trong file cấu hình
    if grep -iq "hardware ethernet[[:space:]]\+$mac;" "$CONFIG_FILE"; then
        echo  "Địa chỉ MAC đã tồn tại."
        return 1
    fi

    return 0
}

is_valid_host_ip(){
    local host_ip="$1"

    # kiểm tra định dạng hợp lệ
    if ! is_valid_ip "$host_ip"; then
        echo "IP không đúng định dạng"
        return 1
    fi

    # kiểm tra không trùng trong file cấu hình
    if grep -q "fixed-address[[:space:]]\+$host_ip;" "$CONFIG_FILE"; then
        echo "IP đã tồn tại."
        return 1
    fi

    # kiểm tra thuộc subnet đã chọn 
    if ! is_ip_in_subnet "$host_ip"; then
        echo "IP không thuộc subnet."
        return 1
    fi

    # kiểm tra không thuộc subnet range
    local start_int=$(ip_to_int "$range_start")
    local end_int=$(ip_to_int "$range_end")
    local host_ip_int=$(ip_to_int "$host_ip")
    if (( host_ip_int >= start_int && host_ip_int <= end_int )); then
        echo "IP không được nằm trong phạm vi IP cấp phát"
        return 1
    fi

    # kiểm tra khác địa chỉ broadcast, subnet, domain_name_addr, router
    if [[ "$host_ip" == "$subnet" || "$host_ip" == "$broadcast_addr" || "$host_ip" == "$domain_name_addr" || "$host_ip" == "$router" ]]; then
        echo "IP không được trùng với địa chỉ subnet, broadcast, domain_name_server, router"
        return 1
    fi
    return 0
}

# TrongHiuuu 19/9/2025 - Hàm chọn subnet và hiển thị các thông tin liên quan
select_subnet() {
    echo "Danh sách subnet khả dụng:"
    mapfile -t subnets < <(grep -E "^subnet" "$CONFIG_FILE")

    if [ ${#subnets[@]} -eq 0 ]; then
        echo "Không tìm thấy subnet nào trong file $CONFIG_FILE"
        return 1
    fi

    # Hiển thị danh sách subnet
    local i=1
    for line in "${subnets[@]}"; do
        echo "$i) $(echo "$line" | tr -d '{')"
        ((i++))
    done


    # Yêu cầu chọn
    local choice
    while true; do
        read -p "Chọn subnet (1-${#subnets[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#subnets[@]} )); then
            break
        else
            echo "Lựa chọn không hợp lệ."
        fi
    done

    # Lấy dòng subnet được chọn
    local selected="${subnets[$((choice-1))]}"

    # Parse subnet + netmask
    subnet=$(echo "$selected" | awk '{print $2}')
    netmask=$(echo "$selected" | awk '{print $4}' | tr -d '{')


    # Lấy range start & end
    range_start=$(awk "/subnet $subnet netmask $netmask/,/}/" "$CONFIG_FILE" | grep range | awk '{print $2}' | tr -d ';')
    range_end=$(awk "/subnet $subnet netmask $netmask/,/}/" "$CONFIG_FILE" | grep range | awk '{print $3}' | tr -d ';')

    # Lấy broadcast
    broadcast_addr=$(awk "/subnet $subnet netmask $netmask/,/}/" "$CONFIG_FILE" | grep broadcast-address | awk '{print $2}' | tr -d ';')

    # Lấy domain-server-address
    domain_name_addr=$(awk "/subnet $subnet netmask $netmask/,/}/" "$CONFIG_FILE" | grep domain-name-servers | awk '{print $2}' | tr -d ';')

    # Lấy router
    router=$(awk "/subnet $subnet netmask $netmask/,/}/" "$CONFIG_FILE" | grep routers | awk '{print $2}' | tr -d ';')

    return 0
}

# ----------------- HÀM NHẬP INPUT ------------------------------
input_subnet(){
    while true; do
        read -p "Nhập subnet (vd: 192.168.1.0): " subnet
        if is_valid_subnet "$subnet"; then
            break
        fi
    done
}

input_netmask(){
    while true; do
        read -p "Nhập netmask (vd: 255.255.255.0): " netmask
        if is_valid_netmask "$netmask"; then
           break
        fi
    done
}

input_range(){
    echo "Nhập phạm vi IP cấp phát"
    while true; do
        read -p "Nhập range_start (vd: 192.168.1.10): " range_start
        read -p "Nhập range_end (vd: 192.168.1.100): " range_end
        if is_valid_range "$range_start" "$range_end"; then
            break
        fi
    done
}

input_router(){
    while true; do
        read -p "Nhập địa chỉ router (vd: 192.168.1.1): " router
        if is_valid_router "$router"; then
            break
        fi
    done
}

input_default_lease_time(){
    while true; do
        read -p "Nhập default_lease_time (vd: 600): " default_lease_time
        if is_time_positive "$default_lease_time"; then
            break
        fi
    done
}

input_max_lease_time(){
    while true; do
        read -p "Nhập max_lease_time (vd: 7200): " max_lease_time
        if is_time_positive "$max_lease_time"; then
            if [ "$default_lease_time" -le "$max_lease_time" ]; then
                break
            else
                echo "Thời gian tối đa phải lớn hơn hoặc bằng thời gian mặc định, vui lòng nhập lại!"
            fi
        fi
    done
}

input_domain_name_server() {
    # regex: Theo chuan FQDN
    local dns_regex="^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[a-zA-Z]{2,}$"
    while true; do
        read -p "Nhập tên máy chủ miền (vd: server.sgu.edu.vn): " domain_name_server
        if [[ $domain_name_server =~ $dns_regex ]]; then
            break
        else
            echo "Sai định dạng tên máy chủ miền ! Vui lòng nhập lại (dạng FQDN, vd: server.sgu.edu.vn)."
        fi
    done
}

# Input and validate domain_name
input_domain_name() {
    local dn_regex="^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[a-zA-Z]{2,}$"
    while true; do
        read -p "Nhập tên miền (vd: sgu.edu.vn): " domain_name
        if [[ $domain_name =~ $dn_regex ]]; then
            break
        else
            echo "Sai định dạng tên miền! Vui lòng nhập lại (dạng domain, vd: sgu.edu.vn)."
        fi
    done
}

# Input and validate domain_name_adrr (IPv4)
input_domain_name_addr() {
    while true; do
        read -p "Nhập địa chỉ DNS server (vd: 192.168.1.1): " domain_name_addr
        if is_valid_domain_name_addr "$domain_name_addr"; then
            break
        fi
    done
}

# TrongHiuuu-19/9/2025 - Input cho host tĩnh
input_host_name() {
    while true; do
        read -p "Nhập tên host: " host_name
        if is_valid_host_name "$host_name"; then
            break
        fi
    done
}

input_host_mac() {
    while true; do
        read -p "Nhập địa chỉ MAC (vd: 00:1A:2B:3C:4D:5E): " host_mac
        if is_valid_mac "$host_mac"; then
            break
        fi
    done
}

input_host_ip() {
    while true; do
        read -p "Nhập IP tĩnh cho host: " host_ip
        if is_valid_host_ip "$host_ip"; then
            break
        fi
    done
}


# ----------------- HÀM CHỨC NĂNG ------------------------------
add(){
    input_netmask
    input_subnet
    broadcast_addr=$(calculate_broadcast)
    input_range
    input_router
    input_default_lease_time
    input_max_lease_time
    input_domain_name_server
    input_domain_name
    input_domain_name_addr

    # nối chuỗi conf vào config_file
    cat<<EOF >> "$CONFIG_FILE"

subnet $subnet netmask $netmask {
    range $range_start $range_end;
    option domain-name-servers $domain_name_addr, $domain_name_server;
    option domain-name "$domain_name";
    option broadcast-address $broadcast_addr;
    option routers $router;
    default-lease-time $default_lease_time;
    max-lease-time $max_lease_time;
}
EOF
}

edit(){
    local choice
    read -p "Nhập subnet cần sửa: " subnet
    read -p "Nhập netmask cần sửa: " netmask
    if grep -q "subnet $subnet netmask $netmask" "$CONFIG_FILE"; then
        broadcast_addr=$(calculate_broadcast)
        while true; do
            echo " ________________________"
            echo "| Chọn thông số cần sửa  |"
            echo "|________________________|"
            echo "| 0. Thoát               |"
            echo "| 1. Phạm vi IP cấp phát |"
            echo "| 2. Máy chủ miền        |"
            echo "| 3. Tên miền            |"
            echo "| 4. Địa chỉ router      |"
            echo "| 5. Default lease time  |"
            echo "| 6. Max lease time      |"
            echo "|________________________|"
            echo "|   @Hương - Hiếu - Vy   |"
            echo "|________________________|"
            read -p "Nhập lựa chọn: " choice
            case $choice in
                1) input_range
                    sed -i "/subnet $subnet netmask $netmask/,/}/{s/range.*/range $range_start $range_end;/}" "$CONFIG_FILE"
                    ;;
                2) input_domain_name_server
                    input_domain_name_addr
                    sed -i "/subnet $subnet netmask $netmask/,/}/{s/domain-name-servers.*/domain-name-servers $domain_name_addr, $domain_name_server;/}" "$CONFIG_FILE"
                    ;;
                3) input_domain_name
                    sed -i "/subnet $subnet netmask $netmask/,/}/{s/domain-name .*/domain-name \"$domain_name\";/}" "$CONFIG_FILE"
                    ;;
                4) input_router
                    sed -i "/subnet $subnet netmask $netmask/,/}/{s/routers.*/routers $router;/}" "$CONFIG_FILE"
                    ;;
                5) input_default_lease_time
                    sed -i "/subnet $subnet netmask $netmask/,/}/{s/default-lease-time.*/default-lease-time $default_lease_time;/}" "$CONFIG_FILE"
                    ;;
                6) input_max_lease_time
                    sed -i "/subnet $subnet netmask $netmask/,/}/{s/max-lease-time.*/max-lease-time $max_lease_time;/}" "$CONFIG_FILE"
                    ;;
                0) menu;;
                *) echo "Lựa chọn không hợp lệ, vui lòng nhập lại!";;
            esac
        done
    else 
        echo "Không tìm thấy subnet"
    fi
}

delete(){
    read -p "Nhập subnet cần xóa: " subnet
    read -p "Nhập netmask cần xóa: " netmask

    if grep -q "subnet $subnet netmask $netmask" "$CONFIG_FILE"; then
        sed -i "/subnet $subnet netmask $netmask/,/}/d" "$CONFIG_FILE"
        echo "Đã xóa thành công"
    else 
        echo "Không tìm thấy subnet"
    fi
}

# TrongHiuuu 19/9/2025 - Hàm thêm host tĩnh
add_static_host() {
    if ! select_subnet; then
        return
    fi

    input_host_name
    input_host_mac
    input_host_ip

    # nối chuỗi host vào config_file
    cat<<EOF >> "$CONFIG_FILE"

host $host_name {
    hardware ethernet $host_mac;
    fixed-address $host_ip;
}
EOF

    echo "Đã cấp phát tĩnh thành công"
}

# TrongHiuuu 21/9/2025 - Delete Static Host
delete_static_host() {
    read -p "Nhập tên host cần xóa: " host_name

    if grep -q "host $host_name" "$CONFIG_FILE"; then
        sed -i "/host $host_name/,/}/d" "$CONFIG_FILE"
        echo "Đã xóa thành công"
    else 
        echo "Không tìm thấy host"
    fi
}


start_service(){
    systemctl start $SERVICE
    if [ $? -eq 0 ]; then
        systemctl enable $SERVICE
        if [ $? -eq 0 ]; then 
            echo "Start dịch vụ thành công"
        else 
            echo "Đã xảy ra lỗi"
        fi
    else 
        echo "Đã xảy ra lỗi"
    fi
}

restart_service(){
    #truncate file lease
    [ -f /var/lib/dhcpd/dhcpd.leases ] && truncate -s 0 /var/lib/dhcpd/dhcpd.leases

    systemctl restart $SERVICE
    if [ $? -eq 0 ]; then
        echo "Restart dịch vụ thành công"
    else 
        echo "Đã xảy ra lỗi"
    fi
}

menu(){
local choice
while true; do
    echo " _______________________"
    echo "|    DHCP Autoscript    |"
    echo "|_______________________|"
    echo "| 0. Thoát              |"
    echo "| 1. Tạo subnet         |"
    echo "| 2. Cập nhật subnet    |"
    echo "| 3. Xóa subnet         |"
    echo "| 4. Thêm host tĩnh     |"
    echo "| 5. Xóa host tĩnh      |"
    echo "| 6. Start dịch vụ      |"
    echo "| 7. Restart dịch vụ    |"
    echo "|_______________________|"
    echo "|   @Hương - Hiếu - Vy  |"
    echo "|_______________________|"
    read -p "Nhập lựa chọn: " choice

    case $choice in
    1) add;;
    2) edit;;
    3) delete;;
    4) add_static_host;;
    5) delete_static_host;;
    6) start_service;;
    7) restart_service;;
    0) exit 0;;
    *) echo "Lựa chọn không hợp lệ, vui lòng nhập lại!";;
    esac
done
}

# ----------------- CODE THỰC THI ------------------------------
menu

