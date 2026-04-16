variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.128.0/20", "10.0.144.0/20"]
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-north-1a", "eu-north-1b"]
}
