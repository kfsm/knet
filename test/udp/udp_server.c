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
  int sock;
  struct sockaddr_in stSockAddr,source;
  int size = 100;
  int addr_len = sizeof(struct sockaddr_in);
  char data[2000];

  bzero(&stSockAddr, sizeof(stSockAddr));
  stSockAddr.sin_family = AF_INET;
  stSockAddr.sin_port = htons(6001);
  stSockAddr.sin_addr.s_addr = htonl(INADDR_ANY);
  sock = socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
  bind(sock,(struct sockaddr*)&stSockAddr,addr_len);

  printf("Wating for message\n\r");
  while (1)
  {
    size = recvfrom(sock,data,2000,0,(struct sockaddr*)&source,&addr_len);
    sendto(sock,data,size,0,(struct sockaddr*)&source,addr_len);
  }
  close(sock);
  return 0;
}
