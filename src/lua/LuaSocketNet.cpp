// The net.listen Lua binding: a minimal HTTP listener that lets an external
// local process (the MCP bridge, powder_toy_mcp.py) drive this game through
// bridge_src/_base/bridge_base.lua's handleRequest(body) -> jsonString
// dispatcher, the same way the in-game Lua console does.
//
// This used to exist (see LuaSocket.cpp's history/comments) but was lost and
// replaced with a no-op stub, which is why net was reported as nil at
// runtime. Rebuilt from scratch here, restricted to loopback only -- this is
// a local automation bridge for the person already running the game, not a
// service meant to be reachable from the network.
//
// Deliberately simple rather than a full async multi-connection server: one
// listener accepts and serves at most one request per Simulation tick
// (LuaScriptInterface.cpp's OnTick -> LuaSocket::Process), which is more
// than enough for a single local MCP client issuing one tool call at a time.
// A short SO_RCVTIMEO bounds the one blocking step (reading the rest of an
// already-accepted request) so a stalled client can't hang the game.
#include "LuaScriptInterface.h"
#include "LuaSmartRef.h"
#include "Misc.h"
#include <vector>
#include <string>
#include <cctype>
#include <cstring>
#include <cstdlib>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
using SocketHandle = SOCKET;
static constexpr SocketHandle kInvalidSocket = INVALID_SOCKET;
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
using SocketHandle = int;
static constexpr SocketHandle kInvalidSocket = -1;
#endif

namespace LuaSocket
{

namespace
{
	struct Listener
	{
		SocketHandle fd;
		LuaSmartRef handler;
	};

	std::vector<Listener> listeners;

	void EnsureNetInit()
	{
		static bool inited = false;
		if (inited)
		{
			return;
		}
		inited = true;
#ifdef _WIN32
		WSADATA wsaData;
		WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif
	}

	void CloseSocket(SocketHandle fd)
	{
#ifdef _WIN32
		closesocket(fd);
#else
		close(fd);
#endif
	}

	void SetNonBlocking(SocketHandle fd)
	{
#ifdef _WIN32
		u_long mode = 1;
		ioctlsocket(fd, FIONBIO, &mode);
#else
		int flags = fcntl(fd, F_GETFL, 0);
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
	}

	void SetRecvTimeout(SocketHandle fd, int seconds)
	{
#ifdef _WIN32
		DWORD timeoutMs = DWORD(seconds * 1000);
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeoutMs, sizeof(timeoutMs));
#else
		timeval tv{ seconds, 0 };
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));
#endif
	}

	// Reads one HTTP/1.1 request off an already-accepted socket: headers up
	// to the blank line, then exactly Content-Length more bytes of body.
	bool ReadHttpRequestBody(SocketHandle fd, std::string &body)
	{
		std::string buf;
		char chunk[4096];
		size_t headerEnd = std::string::npos;
		while (headerEnd == std::string::npos)
		{
			int n = recv(fd, chunk, sizeof(chunk), 0);
			if (n <= 0)
			{
				return false;
			}
			buf.append(chunk, size_t(n));
			headerEnd = buf.find("\r\n\r\n");
			if (buf.size() > (1u << 20))
			{
				return false; // headers unreasonably large, bail
			}
		}
		size_t contentLength = 0;
		{
			std::string headers = buf.substr(0, headerEnd);
			for (auto &c : headers)
			{
				c = char(std::tolower((unsigned char)c));
			}
			auto pos = headers.find("content-length:");
			if (pos != std::string::npos)
			{
				pos += std::strlen("content-length:");
				while (pos < headers.size() && headers[pos] == ' ')
				{
					pos++;
				}
				contentLength = size_t(std::atoll(headers.c_str() + pos));
			}
		}
		size_t bodyStart = headerEnd + 4;
		while (buf.size() - bodyStart < contentLength)
		{
			int n = recv(fd, chunk, sizeof(chunk), 0);
			if (n <= 0)
			{
				return false;
			}
			buf.append(chunk, size_t(n));
		}
		body = buf.substr(bodyStart, contentLength);
		return true;
	}

	void SendHttpResponse(SocketHandle fd, const std::string &responseBody)
	{
		std::string resp = "HTTP/1.1 200 OK\r\n"
			"Content-Type: application/json\r\n"
			"Connection: close\r\n"
			"Content-Length: " + std::to_string(responseBody.size()) + "\r\n"
			"\r\n" + responseBody;
		size_t sent = 0;
		while (sent < resp.size())
		{
			int n = send(fd, resp.data() + sent, int(resp.size() - sent), 0);
			if (n <= 0)
			{
				break;
			}
			sent += size_t(n);
		}
	}

	int LuaNetListen(lua_State *L)
	{
		EnsureNetInit();
		int port = int(luaL_checknumber(L, 1));
		luaL_checktype(L, 2, LUA_TFUNCTION);

		SocketHandle fd = socket(AF_INET, SOCK_STREAM, 0);
		if (fd == kInvalidSocket)
		{
			lua_pushnil(L);
			lua_pushstring(L, "socket() failed");
			return 2;
		}
		int reuse = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));

		sockaddr_in addr{};
		addr.sin_family = AF_INET;
		addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // loopback only, see file header
		addr.sin_port = htons(uint16_t(port));

		if (bind(fd, (sockaddr *)&addr, sizeof(addr)) != 0)
		{
			CloseSocket(fd);
			lua_pushnil(L);
			lua_pushstring(L, "bind() failed (port in use?)");
			return 2;
		}
		if (listen(fd, 8) != 0)
		{
			CloseSocket(fd);
			lua_pushnil(L);
			lua_pushstring(L, "listen() failed");
			return 2;
		}
		SetNonBlocking(fd);

		listeners.emplace_back();
		auto &entry = listeners.back();
		entry.fd = fd;
		entry.handler.Assign(L, 2);

		lua_newtable(L);
		lua_pushinteger(L, port);
		lua_setfield(L, -2, "port");
		return 1;
	}

	void OpenNet(lua_State *L)
	{
		static const luaL_Reg reg[] = {
			{ "listen", LuaNetListen },
			{ nullptr, nullptr }
		};
		lua_newtable(L);
		luaL_register(L, nullptr, reg);
		lua_setglobal(L, "net");
	}
}

void OpenNetTable(lua_State *L)
{
	OpenNet(L);
}

void Process(lua_State *L)
{
	for (auto &listener : listeners)
	{
		sockaddr_in clientAddr{};
#ifdef _WIN32
		int clientLen = sizeof(clientAddr);
#else
		socklen_t clientLen = sizeof(clientAddr);
#endif
		SocketHandle client = accept(listener.fd, (sockaddr *)&clientAddr, &clientLen);
		if (client == kInvalidSocket)
		{
			continue; // nothing pending this tick -- the common case
		}

		SetRecvTimeout(client, 2);

		std::string body;
		if (ReadHttpRequestBody(client, body))
		{
			if (listener.handler.Push(L) == LUA_TFUNCTION)
			{
				lua_pushlstring(L, body.data(), body.size());
				if (lua_pcall(L, 1, 1, 0) == 0 && lua_isstring(L, -1))
				{
					size_t len = 0;
					const char *resp = lua_tolstring(L, -1, &len);
					SendHttpResponse(client, std::string(resp, len));
				}
				else
				{
					SendHttpResponse(client, "{\"ok\":false,\"error\":\"handler error\"}");
				}
			}
			lua_pop(L, 1);
		}
		CloseSocket(client);
	}
}

}
