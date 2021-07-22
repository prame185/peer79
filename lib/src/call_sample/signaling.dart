import 'dart:convert';
import 'dart:async';
import 'dart:developer';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'random_string.dart';

import '../utils/device_info.dart'
    if (dart.library.js) '../utils/device_info_web.dart';
import '../utils/websocket.dart'
    if (dart.library.js) '../utils/websocket_web.dart';
import '../utils/turn.dart' if (dart.library.js) '../utils/turn_web.dart';

enum SignalingState {
  ConnectionOpen,
  ConnectionClosed,
  ConnectionError,
}

enum CallState {
  CallStateNew,
  CallStateRinging,
  CallStateInvite,
  CallStateConnected,
  CallStateBye,
}

/*
 * callbacks for Signaling API.
 */
typedef void SignalingStateCallback(SignalingState state);
typedef void CallStateCallback(Session session, CallState state);
typedef void StreamStateCallback(Session session, MediaStream stream);
typedef void OtherEventCallback(dynamic event);
typedef void DataChannelMessageCallback(
    Session session, RTCDataChannel dc, RTCDataChannelMessage data);
typedef void DataChannelCallback(Session session, RTCDataChannel dc);

class Session {
  Session({this.sid, this.pid});
  String pid;
  String sid;
  RTCPeerConnection share;
  RTCPeerConnection pc;
  RTCDataChannel dc;
  List<RTCIceCandidate> remoteCandidates = [];
}

class Signaling {
  Signaling(this._host);

  JsonEncoder _encoder = JsonEncoder();
  JsonDecoder _decoder = JsonDecoder();
  String _selfId = randomNumeric(6);
  SimpleWebSocket _socket;
  var _host;
  var _port = 8086;
  var _turnCredential;
  Map<String, Session> _sessions = {};
  MediaStream _localStream;
  List<MediaStream> _remoteStreams = <MediaStream>[];

  SignalingStateCallback onSignalingStateChange;
  CallStateCallback onCallStateChange;
  StreamStateCallback onLocalStream;
  StreamStateCallback onAddRemoteStream;
  StreamStateCallback onRemoveRemoteStream;
  OtherEventCallback onPeersUpdate;
  DataChannelMessageCallback onDataChannelMessage;
  DataChannelCallback onDataChannel;

  String get sdpSemantics =>
      WebRTC.platformIsWindows ? 'plan-b' : 'unified-plan';

  Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'url': 'stun:stun.l.google.com:19302'},
      /*
       * turn server configuration example.
      {
        'url': 'turn:123.45.67.89:3478',
        'username': 'change_to_real_user',
        'credential': 'change_to_real_secret'
      },
      */
    ]
  };

  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ]
  };

  final Map<String, dynamic> _dcConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };

  close() async {
    await _cleanSessions();
    if (_socket != null) _socket.close();
  }

  void switchCamera() {
    if (_localStream != null) {
      Helper.switchCamera(_localStream.getVideoTracks()[0]);
    }
  }

  void muteMic() {
    if (_localStream != null) {
      bool enabled = _localStream.getAudioTracks()[0].enabled;
      _localStream.getAudioTracks()[0].enabled = !enabled;
    }
  }

  void invite(String peerId, String media, bool useScreen) async {
    var sessionId = _selfId + '-' + peerId;
    Session session = await _createSession(
        peerId: peerId,
        sessionId: sessionId,
        media: media,
        screenSharing: useScreen);
    _sessions[sessionId] = session;
    if (media == 'data') {
      _createDataChannel(session);
    }
    //_createOffer(session, media);
  }

  void bye(String sessionId) {
    // _send('bye', {
    //   'session_id': sessionId,
    //   'from': _selfId,
    // });

    _closeSession(_sessions[sessionId]);
  }

  void onMessage(e) async {
    var tokens = e.split("|");
    print("tokens:$tokens");
    var cmd = tokens[1];
    print("cmd:$cmd");
    Map<String, dynamic> data = _decoder.convert(tokens[2]);
    print("data:$data");
    switch (cmd) {
      case 'res-yp':
        break;
      case 'sign':
        print("type:${data['msg']['type']}");
        switch (data['msg']['type']) {
          case 'offer':
            var from = data['from'];
            var jsd = data['msg'];
            var token = jsd['token'];

            var peerId = data['from'];
            var description = data['msg']['offer'];
            print("description:$description");
            if (description != null) {
              var media = data['media'];
              var sessionId = data['from'];
              var session = _sessions[sessionId];
              print("sessionId:$sessionId, session:$session");
              var newSession = await _createSession(
                  session: session,
                  peerId: peerId,
                  sessionId: sessionId,
                  media: media,
                  screenSharing: true);
              print("newSession:$newSession");
              _sessions[sessionId] = newSession;
              await newSession.pc.setRemoteDescription(RTCSessionDescription(
                  description['sdp'], description['type']));
              await _createAnswer(newSession, media);
              if (newSession.remoteCandidates.length > 0) {
                newSession.remoteCandidates.forEach((candidate) async {
                  await newSession.pc.addCandidate(candidate);
                });
                newSession.remoteCandidates.clear();
              }
              onCallStateChange?.call(newSession, CallState.CallStateNew);
              //await Future.delayed(Duration(seconds: 3));
              //_createOffer(newSession, media);
            }

            break;
          case 'ice':
            var peerId = data['from'];
            var candidateMap = data['msg']['ice'];
            print("sessions:$_sessions");
            print("candidateMap:$candidateMap");
            if (candidateMap != null) {
              var sessionId = data['from'];
              var session = _sessions[sessionId];
              RTCIceCandidate candidate = RTCIceCandidate(
                  candidateMap['candidate'],
                  candidateMap['sdpMid'],
                  candidateMap['sdpMLineIndex']);
              if (session == null) {
                await Future.delayed(Duration(seconds: 1));
              }
              print("session==null : ${session == null}");
              if (session != null) {
                print("session.pc==null : ${session.pc == null}");
                if (session.pc != null) {
                  await session.pc.addCandidate(candidate);
                } else {
                  session.remoteCandidates.add(candidate);
                }
              } else {
                // _sessions[sessionId] = Session(pid: peerId, sid: sessionId)
                //   ..remoteCandidates.add(candidate);
              }
            }
            break;
          case 'cancel':
            break;
          default:
        }
        break;
      default:
    }
  }

  Future<void> connect() async {
    //var url = 'https://$_host:$_port/ws';
    var url = 'https://www.peer79.com/p2p-ws';
    _socket = SimpleWebSocket(url);

    print('connect to $url');

    if (_turnCredential == null) {
      try {
        _turnCredential = await getTurnCredential(_host, _port);
        /*{
            "username": "1584195784:mbzrxpgjys",
            "password": "isyl6FF6nqMTB9/ig5MrMRUXqZg",
            "ttl": 86400,
            "uris": ["turn:127.0.0.1:19302?transport=udp"]
          }
        */
        _iceServers = {
          'iceServers': [
            {
              'urls': _turnCredential['uris'][0],
              'username': _turnCredential['username'],
              'credential': _turnCredential['password']
            },
          ]
        };
      } catch (e) {}
    }

    _socket.onOpen = () async {
      print('onOpen');
      onSignalingStateChange?.call(SignalingState.ConnectionOpen);
      // _send('new', {
      //   'name': DeviceInfo.label,
      //   'id': _selfId,
      //   'user_agent': DeviceInfo.userAgent
      // });
      //_send('cntl', 'get-id', {});

      _send('ss', 'req-yp', {
        'data': {
          'wp': {'name': 'zzzz'}
        },
        'gid': _host,
        'did': _selfId
      });
    };

    _socket.onMessage = (message) {
      print('Received data: ' + message);
      //onMessage(_decoder.convert(message));
      onMessage(message);
    };

    _socket.onClose = (int code, String reason) {
      print('Closed by server [$code => $reason]!');
      onSignalingStateChange?.call(SignalingState.ConnectionClosed);
    };

    await _socket.connect();
  }

  Future<MediaStream> createStream(String media, bool userScreen) async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': {
        'mandatory': {
          'minWidth':
              '640', // Provide your own width, height and frame rate here
          'minHeight': '480',
          'minFrameRate': '30',
        },
        'facingMode': 'user',
        'optional': [],
      }
    };

    MediaStream stream = userScreen
        ? await navigator.mediaDevices.getDisplayMedia(mediaConstraints)
        : await navigator.mediaDevices.getUserMedia(mediaConstraints);
    onLocalStream?.call(null, stream);
    return stream;
  }

  Future<Session> _createSession(
      {Session session,
      String peerId,
      String sessionId,
      String media,
      bool screenSharing}) async {
    print("_createSession");
    var newSession = session ?? Session(sid: sessionId, pid: peerId);
    // if (media != 'data')
    //   _localStream = await createStream(media, screenSharing);
    print("_iceServers:$_iceServers");
    RTCPeerConnection pc = await createPeerConnection({
      ..._iceServers,
      ...{'sdpSemantics': sdpSemantics}
    }, _config);
    print("media:$media");
    if (media != 'data') {
      print("sdpSemantics:$sdpSemantics");
      switch (sdpSemantics) {
        case 'plan-b':
          pc.onAddStream = (MediaStream stream) {
            onAddRemoteStream?.call(newSession, stream);
            _remoteStreams.add(stream);
          };
          //await pc.addStream(_localStream);
          break;
        case 'unified-plan':

          // Unified-Plan
          pc.onTrack = (event) {
            if (event.track.kind == 'video') {
              onAddRemoteStream?.call(newSession, event.streams[0]);
            }
          };
          print("pc:$pc");
          // _localStream.getTracks().forEach((track) {
          //   print("addTrack:$track");
          //   pc.addTrack(track, _localStream);
          // });
          break;
      }

      // Unified-Plan: Simuclast
      /*
      await pc.addTransceiver(
        track: _localStream.getAudioTracks()[0],
        init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly, streams: [_localStream]),
      );

      await pc.addTransceiver(
        track: _localStream.getVideoTracks()[0],
        init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly,
            streams: [
              _localStream
            ],
            sendEncodings: [
              RTCRtpEncoding(rid: 'f', active: true),
              RTCRtpEncoding(
                rid: 'h',
                active: true,
                scaleResolutionDownBy: 2.0,
                maxBitrate: 150000,
              ),
              RTCRtpEncoding(
                rid: 'q',
                active: true,
                scaleResolutionDownBy: 4.0,
                maxBitrate: 100000,
              ),
            ]),
      );*/
      /*
        var sender = pc.getSenders().find(s => s.track.kind == "video");
        var parameters = sender.getParameters();
        if(!parameters)
          parameters = {};
        parameters.encodings = [
          { rid: "h", active: true, maxBitrate: 900000 },
          { rid: "m", active: true, maxBitrate: 300000, scaleResolutionDownBy: 2 },
          { rid: "l", active: true, maxBitrate: 100000, scaleResolutionDownBy: 4 }
        ];
        sender.setParameters(parameters);
      */
    }
    pc.onIceCandidate = (candidate) {
      if (candidate == null) {
        print('onIceCandidate: complete!');
        return;
      }
      // _send('candidate', {
      //   'to': peerId,
      //   'from': _selfId,
      //   'candidate': {
      //     'sdpMLineIndex': candidate.sdpMlineIndex,
      //     'sdpMid': candidate.sdpMid,
      //     'candidate': candidate.candidate,
      //   },
      //   'session_id': sessionId,
      // });
      _send('ss', 'sign', {
        //'to': session.pid,
        'to': newSession.sid,
        'did': _selfId,
        'msg': {
          'token': _host,
          'type': 'ice',
          'ice': {
            'sdpMLineIndex': candidate.sdpMlineIndex,
            'sdpMid': candidate.sdpMid,
            'candidate': candidate.candidate,
          },
        }
      });
    };

    pc.onIceConnectionState = (state) async {
      print("state:$state");
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        RTCPeerConnection share = await createPeerConnection({
          ..._iceServers,
          ...{'sdpSemantics': sdpSemantics}
        }, _config);
        _localStream = await createStream(media, screenSharing);
        _localStream.getTracks().forEach((track) {
          print("addTrack:$track");
          share.addTrack(track, _localStream);
        });
        share.onIceCandidate = (candidate) {
          if (candidate == null) {
            print('onIceCandidate: complete!');
            return;
          }
          _sendDc(
              'sign',
              {
                //'to': session.pid,
                'type': 'ice',
                'ice': {
                  'sdpMLineIndex': candidate.sdpMlineIndex,
                  'sdpMid': candidate.sdpMid,
                  'candidate': candidate.candidate,
                },
                'mode': 'share'
              },
              newSession);
        };
        newSession.share = share;
        _createOffer(newSession, media);
        //newSession.dc.
      }
    };

    pc.onRemoveStream = (stream) {
      onRemoveRemoteStream?.call(newSession, stream);
      _remoteStreams.removeWhere((it) {
        return (it.id == stream.id);
      });
    };

    pc.onDataChannel = (channel) {
      _addDataChannel(newSession, channel);
    };

    newSession.pc = pc;
    return newSession;
  }

  void _addDataChannel(Session session, RTCDataChannel channel) {
    channel.onDataChannelState = (e) {};
    channel.onMessage = (RTCDataChannelMessage data) {
      print("dataChannel Message : ${data.text}");
      var pool = data.text.split(':');
      pool.removeRange(0, 3);
      var re = _decoder.convert(pool.join(':'));
      print("re:$re");
      print("re:${re['type']}");
      if (re['type'] == "answer") {
        session.share.setRemoteDescription(
            RTCSessionDescription(re['answer']['sdp'], re['answer']['type']));
      } else if (re['type'] == "ice") {
        var candidateMap = re['ice'];
        if (candidateMap != null) {
          RTCIceCandidate candidate = RTCIceCandidate(candidateMap['candidate'],
              candidateMap['sdpMid'], candidateMap['sdpMLineIndex']);
          session.share.addCandidate(candidate);
        }
      }
      onDataChannelMessage?.call(session, channel, data);
    };
    session.dc = channel;
    onDataChannel?.call(session, channel);
  }

  Future<void> _createDataChannel(Session session,
      {label: 'fileTransfer'}) async {
    RTCDataChannelInit dataChannelDict = RTCDataChannelInit()
      ..maxRetransmits = 30;
    RTCDataChannel channel =
        await session.pc.createDataChannel(label, dataChannelDict);
    _addDataChannel(session, channel);
  }

  Future<void> _createOffer(Session session, String media) async {
    try {
      print("\n\n\n\n**************** createOffer1 *****************\n\n\n\n");
      RTCSessionDescription s = await session.share
          .createOffer(media == 'data' ? _dcConstraints : {});
      //
      print("\n\n\n\n**************** createOffer2 *****************\n\n\n\n");

      //
      await session.share.setLocalDescription(s);
      print("\n\n\n\n**************** createOffer3 *****************\n\n\n\n");
      // _send('offer', {
      //   'to': session.pid,
      //   'from': _selfId,
      //   'description': {'sdp': s.sdp, 'type': s.type},
      //   'session_id': session.sid,
      //   'media': media,
      // });

      /*
        share code가 유효하지 않을 경우 아래와 같은 답신이 온다.
        clabs-p2p-v0.1:service:0,1:{
    "type": "error",
    "msg": "invalid code",
    "request": {
        "type": "offer",
        "mode": "share",
        "offer": {
            "type": "offer",
            "sdp": "..."
        },
        "code": "1231"
    }
}
      */
      _sendDc(
          'sign',
          {
            'type': 'offer',
            'offer': {'sdp': s.sdp, 'type': s.type},
            'mode': 'share',
            'code': '123'
          },
          session);
    } catch (e) {
      print(e.toString());
    }
  }

  Future<void> _createAnswer(Session session, String media) async {
    try {
      RTCSessionDescription s =
          await session.pc.createAnswer(media == 'data' ? _dcConstraints : {});
      await session.pc.setLocalDescription(s);
      // _send('answer', {
      //   'to': session.pid,
      //   'from': _selfId,
      //   'description': {'sdp': s.sdp, 'type': s.type},
      //   'session_id': session.sid,
      // });
      _send('ss', 'sign', {
        'to': session.pid,
        'did': _selfId,
        'msg': {
          'token': _host,
          'type': 'answer',
          'answer': {'sdp': s.sdp, 'type': s.type},
        }
      });
    } catch (e) {
      print(e.toString());
    }
  }

  _send(event, type, data) {
    // var request = Map();
    // request["type"] = event;
    // request["data"] = data;
    _socket.send(event + "|" + type + "|" + _encoder.convert(data));
  }

  _sendDc(kind, data, session) {
    // var request = Map();
    // request["type"] = event;
    // request["data"] = data;
    print("_sendDc:" + "clabs-p2p-v0.1:$kind:0,1:" + _encoder.convert(data));
    session.dc.send(RTCDataChannelMessage(
        "clabs-p2p-v0.1:$kind:0,1:" + _encoder.convert(data)));
  }

  Future<void> _cleanSessions() async {
    if (_localStream != null) {
      _localStream.getTracks().forEach((element) async {
        await element.dispose();
      });
      await _localStream.dispose();
      _localStream = null;
    }
    _sessions.forEach((key, sess) async {
      await sess?.pc?.close();
      await sess?.dc?.close();
    });
    _sessions.clear();
  }

  void _closeSessionByPeerId(String peerId) {
    var session;
    _sessions.removeWhere((String key, Session sess) {
      var ids = key.split('-');
      session = sess;
      return peerId == ids[0] || peerId == ids[1];
    });
    if (session != null) {
      _closeSession(session);
      onCallStateChange?.call(session, CallState.CallStateBye);
    }
  }

  Future<void> _closeSession(Session session) async {
    _localStream?.getTracks()?.forEach((element) async {
      await element.dispose();
    });
    await _localStream?.dispose();
    _localStream = null;

    await session?.pc?.close();
    await session?.dc?.close();
  }
}
