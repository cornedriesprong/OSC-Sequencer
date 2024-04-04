//
//  main.c
//  audio-tutorial
//
//  Created by Corné on 13/07/2021.
//

#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <string>
#include <math.h>
#include "portaudio.h"
#include "CPSequencer.h"
#include <ableton/Link.hpp>
#include <ableton/link/HostTimeFilter.hpp>
#include <ableton/platforms/stl/Clock.hpp>
#include <chrono>
#include "RtMidi.h"
#include <CoreFoundation/CoreFoundation.h>
#include "tinyosc.h"

#define NUM_SECONDS (60)
#define SAMPLE_RATE (44100.0)
#define FRAMES_PER_BUFFER (256)

#ifndef M_PI
#define M_PI (3.14159265)
#endif

#define TABLE_SIZE (200)

typedef struct
{
    float sine[TABLE_SIZE];
    int left_phase;
    int right_phase;
    char message[20];
} paTestData;

struct AbletonLink
{
    ableton::Link m_link;
    ableton::Link::SessionState
        sessionState; // should be updated in every callback
    ableton::link::HostTimeFilter<ableton::platforms::stl::Clock>
        hostTimeFilter;

    std::chrono::microseconds m_hosttime; // also updated every callback
    std::chrono::microseconds m_buffer_begin_at_output;

    double m_quantum;
    double m_requested_tempo;
    bool m_reset_beat_time;

    int sampleTime;

    std::chrono::microseconds m_output_latency;

    AbletonLink(double bpm)
        : m_link{bpm},
          sessionState{m_link.captureAudioSessionState()},
          m_quantum{4.},
          m_requested_tempo{0},
          m_reset_beat_time{false},
          sampleTime{0},
          m_output_latency(0)
    {
        // m_link.setTempoCallback(update_bpm);
        m_link.enable(true);
    }
};

AbletonLink *ablLink = new AbletonLink(120);
CPSequencer *sequencer = new CPSequencer(nil, nil);

typedef void (*osc_callback)(tosc_message *osc_message);

void openOSC(osc_callback cb)
{
    char buffer[2048]; // declare a 2Kb buffer to read packet data into

    // open a socket to listen for datagrams (i.e. UDP packets) on port 9000
    const int fd = socket(AF_INET, SOCK_DGRAM, 0);
    fcntl(fd, F_SETFL, O_NONBLOCK); // set the socket to non-blocking
    struct sockaddr_in sin;
    sin.sin_family = AF_INET;
    sin.sin_port = htons(9000);
    sin.sin_addr.s_addr = INADDR_ANY;
    bind(fd, (struct sockaddr *)&sin, sizeof(struct sockaddr_in));
    printf("tinyosc is now listening on port 9000.\n");
    printf("Press Ctrl+C to stop.\n");

    while (true)
    {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);
        struct timeval timeout = {1, 0}; // select times out after 1 second
        if (select(fd + 1, &readSet, NULL, NULL, &timeout) > 0)
        {
            struct sockaddr sa; // can be safely cast to sockaddr_in
            socklen_t sa_len = sizeof(struct sockaddr_in);
            int len = 0;
            while ((len = (int)recvfrom(fd, buffer, sizeof(buffer), 0, &sa, &sa_len)) > 0)
            {
                if (tosc_isBundle(buffer))
                {
                    tosc_bundle bundle;
                    tosc_parseBundle(&bundle, buffer, len);
                    const uint64_t timetag = tosc_getTimetag(&bundle);
                    tosc_message osc;
                    while (tosc_getNextMessage(&bundle, &osc))
                    {
                        //              tosc_printMessage(&osc);
                        cb(&osc);
                    }
                }
                else
                {
                    tosc_message osc;
                    tosc_parseMessage(&osc, buffer, len);
                    cb(&osc);
                    //            tosc_printMessage(&osc);
                }
            }
        }
    }

    // close the UDP socket
    close(fd);
}

static CFStringRef GetEndpointDisplayName(MIDIEndpointRef endpoint)
{
    CFStringRef result = CFSTR(""); // default
    MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &result);
    return result;
}

// CFShow(GetEndpointDisplayName(MIDIGetDestination(0)));
MIDIClientRef client;
CFStringRef name = CFStringCreateWithCString(NULL, "IAC", kCFStringEncodingASCII);
MIDIEndpointRef endpoint = MIDIGetDestination(0);
CFStringRef name1 = CFStringCreateWithCString(NULL, "IAC", kCFStringEncodingASCII);
MIDIPortRef outPort;

// OSStatus s = MIDIClientCreate((CFStringRef)@"PGMidi MIDI Client", nil, nil, &client);

/* This routine will be called by the PortAudio engine when audio is needed.
 ** It may called at interrupt level on some machines so don't do anything
 ** that could mess up the system like calling malloc() or free().
 */
static int patestCallback(const void *inputBuffer, void *outputBuffer,
                          unsigned long framesPerBuffer,
                          const PaStreamCallbackTimeInfo *timeInfo,
                          PaStreamCallbackFlags statusFlags,
                          void *userData)
{
    //    SequencerSettings *data = (SequencerSettings*)userData;
    float *out = (float *)outputBuffer;
    unsigned long i;

    // get beat time from link
    ablLink->sessionState = ablLink->m_link.captureAudioSessionState();
    const auto hostTime =
        ablLink->hostTimeFilter.sampleTimeToHostTime(ablLink->sampleTime);
    ablLink->sampleTime += framesPerBuffer;
    double beatTime = ablLink->sessionState.beatAtTime(hostTime, ablLink->m_quantum);
    ablLink->m_link.commitAudioSessionState(ablLink->sessionState);
    //    printf("%f\n", beatTime);
    //    printf("%lu\n", framesPerBuffer);

    (void)timeInfo; /* Prevent unused variable warnings. */
    (void)statusFlags;
    (void)inputBuffer;

    MIDIPacket midiData[MIDI_PACKET_SIZE][8];
    for (int i = 0; i < MIDI_PACKET_SIZE; i++)
    {
        for (int j = 0; j < 8; j++)
        {
            midiData[i][j].length = 0;
        }
    }

    SequencerSettings settings = {120, SAMPLE_RATE, FRAMES_PER_BUFFER};
    sequencer->renderTimeline(ablLink->sampleTime, settings, beatTime, midiData);

    // schedule MIDI events
    for (int i = 0; i < MIDI_PACKET_SIZE; i++) {
        for (int j = 0; j < 8; j++) {
            if (midiData[i][j].length != 0) {
                MIDIEndpointRef endpoint = MIDIGetDestination(0);
                uint8_t buf[512];
                MIDIPacketList *packetList = (MIDIPacketList *)&buf;
                MIDIPacket *packet = MIDIPacketListInit(packetList);

                struct mach_timebase_info timebase;
                mach_timebase_info(&timebase);
                __block double _msToHostTicks = 1.0 / (((double)timebase.numer / (double)timebase.denom) * 1.0e-6);

                UInt64 frameOffset = midiData[i][j].timeStamp - (UInt64)ablLink->sampleTime;
                Float64 ticksOffset = frameOffset / SAMPLE_RATE;
                ticksOffset *= _msToHostTicks;
                UInt64 timestamp = mach_absolute_time() + ticksOffset;
                MIDIPacketListAdd(packetList,
                                  sizeof(buf),
                                  packet,
                                  timestamp,
                                  midiData[i][j].length,
                                  midiData[i][j].data);
                MIDISend(outPort, endpoint, packetList);
            }
        }
    }

    for (i = 0; i < framesPerBuffer; i++)
    {
        *out++ = 0;
        *out++ = 0;
    }

    return paContinue;
}

/*
 * This routine is called by portaudio when playback is done.
 */
static void StreamFinished(void *userData)
{
    paTestData *data = (paTestData *)userData;
    printf("Stream Completed: %s\n", data->message);
}

void oscCallback(tosc_message *osc)
{
    printf("------------------------------------------------\n");
    char *address = tosc_getAddress(osc); // the OSC address string, e.g. "/button1"
    printf("received OSC message with address: %s\n", address);
    char delim[] = "/";
    char *path1 = strtok(address, delim);   // voice, e.g., 'bd'
    int sequenceIndex = atoi(path1);      // sequence index
    char *path2 = strtok(NULL, delim);
    
    if (strcmp(path2, "clear") == 0) {
        printf("clearing sequence %d\n", sequenceIndex);
        sequencer->clearSequence(sequenceIndex);
    }
   
    float param = atof(path2);     // step number, e.g. 1.25
    printf("%s\n", path2);
    
    for (int i = 0; osc->format[i] != '\0'; i++)
    {
        switch (osc->format[i])
        {
        case 'b':
        {
            const char *b = NULL; // will point to binary data
            int n = 0;            // takes the length of the blob
            tosc_getNextBlob(osc, &b, &n);
            printf(" [%i]", n); // print length of blob
            for (int j = 0; j < n; ++j)
                printf("%02X", b[j] & 0xFF); // print blob bytes
            break;
        }
        case 'm':
        {
            unsigned char *m = tosc_getNextMidi(osc);
            printf(" 0x%02X%02X%02X%02X", m[0], m[1], m[2], m[3]);
            break;
        }
        case 'f':
        {
            printf("received float: %f", tosc_getNextFloat(osc));
            break;
        }

        case 'd':
            printf(" %g", tosc_getNextDouble(osc));
            break;
        case 'i':
        {
            if (strcmp(path2, "length") == 0) {
                int l = tosc_getNextInt32(osc);
                float length = l * 0.25;
                printf("changing sequence %d length to %f\n", sequenceIndex, length);
                sequencer->changeSequenceLength(length, sequenceIndex);
                return;
                
            } else if (strcmp(path2, "speed") == 0) {
                int s = tosc_getNextInt32(osc);
                float speed = s * 0.25;
                printf("changing sequence %d playback speed to %f\n", sequenceIndex, speed);
                sequencer->changeStepDivision(speed, sequenceIndex);
                return;
            }
    
//            int pitch;
//            if (strcmp(voice, "bd") == 0) {
//                pitch = BD;
//            } else if (strcmp(voice, "sn") == 0) {
//                pitch = SN;
//            } else if (strcmp(voice, "hh") == 0) {
//                pitch = HH;
//            } else if (strcmp(voice, "pc") == 0) {
//                pitch = PC;
//            }
            int pitch = tosc_getNextInt32(osc);
            int velocity = tosc_getNextInt32(osc);
            int d = tosc_getNextInt32(osc);
            double duration = d * 0.125;
            int chance = tosc_getNextInt32(osc);
            int skip = tosc_getNextInt32(osc);
            
            double beatTime = param * 0.125;
            // if velocity is zero we don't add any event
            if (velocity == 0) { continue; }
            MIDIEvent ev;
            printf("step: %f\n", param);
            printf("adding MIDI event at beat time: %f, on sequence %s (pitch %d)\n", beatTime, path1, pitch);
           
            // 1st 4 voice are drum channel
            // other channels are bass
            int channel = 0;
            if (sequenceIndex > 3) {
                channel = sequenceIndex;
            }
            
            ev.beatTime = beatTime;
            ev.status = NOTE_ON;
            ev.data1 = pitch;
            ev.data2 = velocity;
            ev.duration = duration;
            ev.chance = chance;
            ev.skip = skip;
            ev.skipCount = 0;
            ev.offset = 0;
            ev.destination = 0;
            ev.channel = channel;
            ev.sequenceIndex = sequenceIndex;
            ev.isRatchet = false;
            ev.queued = true;
            //                if (isOn == 1) {
            sequencer->addMidiEvent(ev);
            //                } else {
            //                    sequencer->deleteMidiEvent(ev);
            //                    printf("is off");
            //                }
            
            // we got all data, return
            return;
        }

        case 'h':
            printf(" %lld", tosc_getNextInt64(osc));
            break;
        case 't':
            printf(" %lld", tosc_getNextTimetag(osc));
            break;
        case 's': {
            const char *str = tosc_getNextString(osc);
            if (strcmp(str, "clear") == 0) {
                printf("sould clear!\n");
            }
            break;
        }
        case 'F':
            printf(" false");
            break;
        case 'I':
            printf(" inf");
            break;
        case 'N':
            printf(" nil");
            break;
        case 'T':
            printf(" true");
            break;
        default:
            printf(" Unknown format: '%c'", osc->format[i]);
            break;
        }
    }
    printf("\n");
}

int main(void)
{

    MIDIClientCreate(name, NULL, NULL, &client);
    MIDISourceCreate(client, name1, &endpoint);
    MIDIOutputPortCreate(client, name1, &outPort);

//        for (int i = 0; i < 16; i++) {
//            MIDIEvent ev;
//            double s = 0.25;
//            double beatTime = i * 0.125;
//            ev.beatTime = beatTime;
//            ev.status = NOTE_ON;
//            ev.data1 = 60;      // pitch
//            ev.data2 = 110;     // velocity
    //        ev.duration = 0.125;
    //        ev.chance = 100;
    //        ev.skip = 0;
    //        ev.skipCount = 0;
    //        ev.offset = 0;
    //        ev.destination = 0;
    //        ev.sequenceIndex = 0;
    //        ev.isRatchet = false;
    //        ev.queued = true;
    //        sequencer->addMidiEvent(ev);
    //    }

    PaStreamParameters outputParameters;
    PaStream *stream;
    PaError err;
    paTestData data;

    /* initialise sinusoidal wavetable */
    //    data.sampleRate = SAMPLE_RATE;
    //    data.tempo = 120;

    err = Pa_Initialize();
    if (err != paNoError)
        goto error;

    outputParameters.device = Pa_GetDefaultOutputDevice(); /* default output device */
    if (outputParameters.device == paNoDevice)
    {
        fprintf(stderr, "Error: No default output device.\n");
        goto error;
    }
    outputParameters.channelCount = 2;         /* stereo output */
    outputParameters.sampleFormat = paFloat32; /* 32 bit floating point output */
    outputParameters.suggestedLatency = Pa_GetDeviceInfo(outputParameters.device)->defaultLowOutputLatency;
    outputParameters.hostApiSpecificStreamInfo = NULL;

    err = Pa_OpenStream(
        &stream,
        NULL, /* no input */
        &outputParameters,
        SAMPLE_RATE,
        FRAMES_PER_BUFFER,
        paClipOff, /* we won't output out of range samples so don't bother clipping them */
        patestCallback,
        &data);
    if (err != paNoError)
        goto error;

    //    sprintf( data.message, "No Message" );
    err = Pa_SetStreamFinishedCallback(stream, &StreamFinished);
    if (err != paNoError)
        goto error;

    err = Pa_StartStream(stream);
    if (err != paNoError)
        goto error;

    openOSC(oscCallback);

    printf("Play for %d seconds.\n", NUM_SECONDS);
    Pa_Sleep(NUM_SECONDS * 1000);

    err = Pa_StopStream(stream);
    if (err != paNoError)
        goto error;

    err = Pa_CloseStream(stream);
    if (err != paNoError)
        goto error;

    Pa_Terminate();
    printf("Test finished.\n");

    return err;
error:
    Pa_Terminate();
    fprintf(stderr, "An error occurred while using the portaudio stream\n");
    fprintf(stderr, "Error number: %d\n", err);
    fprintf(stderr, "Error message: %s\n", Pa_GetErrorText(err));
    return err;
}
