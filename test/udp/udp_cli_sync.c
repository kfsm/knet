#include <sys/types.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <strings.h>
#include <unistd.h>
#include <netinet/in.h>

int main(void)
{
  struct sockaddr_in destination,source;
  int sock, size = 10000;
  int addr_len = sizeof(struct sockaddr_in);
  char data[200] = "TEST\n";
  unsigned long count[3] = {0,0,0};

  bzero(&destination, sizeof(destination));
  destination.sin_family = AF_INET;
  destination.sin_port = htons(6001);
  inet_pton(AF_INET,"127.0.0.1", &destination.sin_addr);

  sock = socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
  while (1)
  {
    addr_len = sizeof(destination);
    printf("send data\n");
    size = sendto(sock,data,5,0,(struct sockaddr*)&destination,addr_len);
    recvfrom(sock,data,2000,0,(struct sockaddr*)&source,&addr_len);
  }
  close(sock);
  return 0;
}
