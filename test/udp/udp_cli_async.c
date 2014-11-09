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
  int sock,i = 0;
  struct sockaddr_in destination,source;
  int size = 10000;
  int addr_len = sizeof(struct sockaddr_in);
  char data[200] = "TEST\n";

  bzero(&destination, sizeof(destination));
  destination.sin_family = AF_INET;
  destination.sin_port = htons(6001);
  inet_pton(AF_INET,"127.0.0.1", &destination.sin_addr);
  sock = socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
  while (1)
  {
    printf("Sending burst ...\n");
    for (i=0;i<5000;i++) {
      addr_len = sizeof(destination);
      size = sendto(sock,data,5,0,(struct sockaddr*)&destination,addr_len);
    }
    for (i=0;i<500;i++) {
      recvfrom(sock,data,2000,0,(struct sockaddr*)&source,&addr_len);
    }
  }
  close(sock);
  return 0;
}
