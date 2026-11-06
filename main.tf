terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

# === Изменения для Windows ===
variable "folder_id" {
  type    = string
  default = "b1gmsg6npalq1lc3v1r6" 
}

variable "ssh_key_path" {
  type    = string
  default = "C:/Users/d.biriukov.MCM/.ssh/id_ed25519.pub"
}

provider "yandex" {
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

# Сеть и подсеть
resource "yandex_vpc_network" "net" {
  name = "balancer-net"
}

resource "yandex_vpc_subnet" "subnet" {
  name           = "balancer-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

# Группа безопасности: разрешаем HTTP (80) и SSH (22)
resource "yandex_vpc_security_group" "sg" {
  name       = "balancer-sg"
  network_id = yandex_vpc_network.net.id

  ingress {
    protocol       = "TCP"
    description    = "HTTP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  ingress {
    protocol       = "TCP"
    description    = "SSH"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  egress {
    protocol       = "ANY"
    description    = "any"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Создание 2 ВМ с помощью count
resource "yandex_compute_instance" "vm" {
  count = 2
  name  = "nginx-vm-${count.index + 1}"
  platform_id = "standard-v3"
  allow_stopping_for_update = true

  resources {
    cores  = 2
    memory = 1
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = "fd8li2lvvfc6bdj4c787" # Ubuntu 22.04 LTS
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.subnet.id
    security_group_ids = [yandex_vpc_security_group.sg.id]
    nat                = true
  }

  metadata = {
    ssh-keys  = "ubuntu:${file(var.ssh_key_path)}"
    user-data = <<EOF
#cloud-config
package_update: true
packages:
  - nginx
runcmd:
  - apt-get remove --purge apache2 -y
  - systemctl stop apache2 || true
  - systemctl disable apache2 || true
  - systemctl start nginx
  - systemctl enable nginx
EOF
  }
}

# Целевая группа
resource "yandex_lb_target_group" "tg" {
  name = "nginx-target-group"

  dynamic "target" {
    for_each = yandex_compute_instance.vm
    content {
      subnet_id = yandex_vpc_subnet.subnet.id
      address   = target.value.network_interface.0.ip_address
    }
  }
}

# Сетевой балансировщик нагрузки (NLB)
resource "yandex_lb_network_load_balancer" "nlb" {
  name = "nginx-balancer"

  listener {
    name = "http-listener"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.tg.id

    healthcheck {
      name = "http-healthcheck"
      http_options {
        port = 80
        path = "/"
      }
      healthy_threshold   = 2
      unhealthy_threshold = 2
      interval            = 2
      timeout             = 1
    }
  }
}

output "balancer_ip" {
  value = [
    for listener in yandex_lb_network_load_balancer.nlb.listener :
    [
      for spec in listener.external_address_spec : spec.address
    ][0]
  ][0]
}

