//
//  CPSequencer.c
//  CPSequencer
//
//  Created by Corné on 16/07/2020.
//  Copyright © 2020 cp3.io. All rights reserved.
//

#include "CPSequencer.h"

enum SequenceOperationType { Add, Delete, Solo, Mute, Change_Length, Change_Step_Division, Clear };

struct SequenceOperation {
    SequenceOperationType type;
    MIDIEvent event;
    double value;
    int sequence;
};

CPSequencer::CPSequencer(callback_t __nullable cb, void * __nullable refCon) {
    
    callback = cb;
    callbackRefCon = refCon;
    playingNotes.reserve(NOTE_CAPACITY * sizeof(PlayingNote));
    TPCircularBufferInit(&fifoBuffer, BUFFER_LENGTH);
    MIDIClockOn = false;
    
    for (int i = 0; i < SEQUENCE_COUNT; i++) {
        MIDISequence sequence = {};
        sequence.eventCount = 0;
        sequence.length = 2;
        // playback ratio: lower == faster
        sequence.playbackRatio = 1.;
        sequences[i] = sequence;
        muteSequences[i] = false;
        soloSequences[i] = false;
        
        prevBeat[i] = -1;
    }
}

double samplesPerBeat(double sampleRate, double tempo) {
    return (sampleRate * 60.0) / tempo;
}

long beatToSamples(double beat, double tempo, double sampleRate) {
    
    long result = (long)(beat / tempo * 60.0 * sampleRate);
    return result ? result : 0;
}

int modPosition(double beat, double length, SequencerSettings settings) {
    
    long positionInSamples = beatToSamples(beat, settings.tempo, settings.sampleRate);
    long lengthInSamples = beatToSamples(length, settings.tempo, settings.sampleRate);
    int result = (int)positionInSamples % lengthInSamples;
    return result ? result : 0;
}

double samplesPerSubtick(double sampleRate, double tempo) {
    return samplesPerBeat(sampleRate, tempo) / PPQ;
}

int subtickPosition(const double beatPosition) {
    
    double integral;
    double fractional = modf(beatPosition, &integral);
    return floor(PPQ * fractional);
}

void CPSequencer::setMIDIClockOn(bool isOn) {
    this->MIDIClockOn = isOn;
}

void CPSequencer::addMidiEvent(MIDIEvent event) {
    
    uint32_t availableBytes = 0;
    SequenceOperation *head = (SequenceOperation *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    SequenceOperation op = { Add, event, 0, event.sequenceIndex };
    head = &op;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(SequenceOperation));
}

void CPSequencer::deleteMidiEvent(MIDIEvent event) {
    
    uint32_t availableBytes = 0;
    SequenceOperation *head = (SequenceOperation *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    SequenceOperation op = { Delete, event, 0, event.sequenceIndex };
    head = &op;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(SequenceOperation));
}

void CPSequencer::clearSequence(int sequenceIndex) {
    
    uint32_t availableBytes = 0;
    SequenceOperation *head = (SequenceOperation *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    MIDIEvent event = {};   // send empty event
    SequenceOperation op = { Clear, event, 0, sequenceIndex };
    head = &op;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(SequenceOperation));
}

void CPSequencer::changeSequenceLength(float length, int sequenceIndex) {
    
    uint32_t availableBytes = 0;
    SequenceOperation *head = (SequenceOperation *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    MIDIEvent event = {};   // send empty event
    SequenceOperation op = { Change_Length, event, length, sequenceIndex };
    head = &op;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(SequenceOperation));
}

void CPSequencer::changeStepDivision(double stepDivision, int sequenceIndex) {
    
    uint32_t availableBytes = 0;
    SequenceOperation *head = (SequenceOperation *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    MIDIEvent event = {};   // send empty event
    SequenceOperation op = { Change_Step_Division, event, stepDivision, sequenceIndex };
    head = &op;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(SequenceOperation));
}

void CPSequencer::setSwing(float swing) {
    this->swing = swing;
}

void CPSequencer::setMute(bool isOn, int sequenceIndex) {
    
    uint32_t availableBytes = 0;
    SequenceOperation *head = (SequenceOperation *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    MIDIEvent event = {};   // send empty event
    float mute = isOn ? 1.0 : 0.0;
    SequenceOperation op = { Mute, event, mute, sequenceIndex };
    head = &op;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(SequenceOperation));
}

void CPSequencer::setSolo(bool isOn, int sequenceIndex) {
    
    uint32_t availableBytes = 0;
    SequenceOperation *head = (SequenceOperation *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    MIDIEvent event = {};   // send empty event
    float solo = isOn ? 1.0 : 0.0;
    SequenceOperation op = { Solo, event, solo, sequenceIndex };
    head = &op;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(SequenceOperation));
}

void CPSequencer::getMidiEventsFromFIFOBuffer() {
    // move MIDI events from FIFO buffer to internal sequencer buffer
    uint32_t bytes = -1;
    while (bytes != 0) {
        SequenceOperation *op = (SequenceOperation *)TPCircularBufferTail(&fifoBuffer, &bytes);
        if (op) {
            switch (op->type) {
                case Add: {
                    MIDISequence *sequence = &sequences[op->sequence];
                    sequence->events[sequence->eventCount] = op->event;
                    sequence->eventCount++;
                    TPCircularBufferConsume(&fifoBuffer, sizeof(SequenceOperation));
                    break;
                }
                    
                case Delete: {
                    MIDISequence *sequence = &sequences[op->sequence];
                    for (int i = 0; i < sequence->eventCount; i++) {
                        if (sequence->events[i].beatTime == op->event.beatTime) {
                            for (int j = i; j < sequence->eventCount; j++) {
                                sequence->events[j] = sequence->events[j + 1];
                            }
                            sequence->eventCount--;
                            TPCircularBufferConsume(&fifoBuffer, sizeof(SequenceOperation));
                            break;
                        }
                    }
                    break;
                }
                    
                case Mute: {
                    bool isOn = op->value == 0.0 ? false : true;
                    muteSequences[op->sequence] = isOn;
                    TPCircularBufferConsume(&fifoBuffer, sizeof(SequenceOperation));
                    break;
                }
                    
                case Solo: {
                    bool isOn = op->value == 0.0 ? false : true;
                    soloSequences[op->sequence] = isOn;
                    TPCircularBufferConsume(&fifoBuffer, sizeof(SequenceOperation));
                    break;
                }
                    
                case Clear: {
                    MIDISequence *sequence = &sequences[op->sequence];
                    sequence->eventCount = 0;
                    memset(sequence->events, 0, sizeof(sequence->events));
                    TPCircularBufferConsume(&fifoBuffer, sizeof(SequenceOperation));
                    break;
                }
                    
                case Change_Length: {
                    MIDISequence *sequence = &sequences[op->sequence];
                    TPCircularBufferConsume(&fifoBuffer, sizeof(SequenceOperation));
                    sequence->length = op->value;
                    break;
                }
                    
                case Change_Step_Division: {
                    MIDISequence *sequence = &sequences[op->sequence];
                    TPCircularBufferConsume(&fifoBuffer, sizeof(SequenceOperation));
                    sequence->playbackRatio = op->value;
                    break;
                }
            }
        }
    }
}

void CPSequencer::stopPlayingNotes(MIDIPacket *midi,
                                   const AUEventSampleTime now,
                                   double beatPosition,
                                   SequencerSettings settings) {
    
    for (int i = 0; i < playingNotes.size(); i++) {
        
        int sequenceIndex = playingNotes[i].sequence;
        MIDISequence *sequence = &sequences[sequenceIndex];
        double length = sequence->length * sequence->playbackRatio;
        long lengthInSamples = beatToSamples(length, settings.tempo, settings.sampleRate);
        int bufferStartTime = modPosition(beatPosition, length, settings);
        int bufferEndTime = bufferStartTime + settings.frameCount;
        double noteOffTime = playingNotes[i].beatTime;
        long eventTime = beatToSamples(noteOffTime, settings.tempo, settings.sampleRate);

        // if the sequence loops around we need to schedule the note off event at the start of the next buffer
        bool loopsAround = (bufferStartTime + settings.frameCount > lengthInSamples) && eventTime <= bufferEndTime;
        bool noteOffIsInCurrentBuffer = eventTime >= bufferStartTime && eventTime < bufferEndTime;
        
        if (noteOffIsInCurrentBuffer || loopsAround) {
            PlayingNote note = playingNotes[i];
            
            int size = midi[note.dest].length;
            midi[note.dest].data[size] = NOTE_OFF + note.channel;
            midi[note.dest].data[size + 1] = note.pitch;
            midi[note.dest].data[size + 2] = 0;
            midi[note.dest].length = size + 3;
            midi[note.dest].timeStamp = now + (eventTime - bufferStartTime);
            
            playingNotes[i].stopped = true;
        }
    }
        
    // remove playing notes that have stopped
    for (int i = 0; i < playingNotes.size(); i++) {
        if (playingNotes[i].stopped) {
            playingNotes.erase(playingNotes.begin() + i);
        }
    }
}

void CPSequencer::addPlayingNoteToMidiData(char status,
                                           AUEventSampleTime offset,
                                           PlayingNote *note,
                                           MIDIPacket *midiData) {
    
    int size = midiData[note->dest].length;
    midiData[note->dest].data[size] = status + note->channel;
    midiData[note->dest].data[size + 1] = note->pitch;
    midiData[note->dest].data[size + 2] = 0;
    midiData[note->dest].length = size + 3;
    midiData[note->dest].timeStamp = note->beatTime;
}

void CPSequencer::addEventToMidiData(char status,
                                     AUEventSampleTime offset,
                                     MIDIEvent *ev,
                                     MIDIPacket *midiData) {
    
    int size = midiData[ev->destination].length;
    midiData[ev->destination].data[size] = status + ev->channel;
    midiData[ev->destination].data[size + 1] = ev->data1;
    midiData[ev->destination].data[size + 2] = ev->data2;
    midiData[ev->destination].length = size + 3;
    midiData[ev->destination].timeStamp = offset;
}

void CPSequencer::scheduleMIDIClock(uint8_t subtick, MIDIPacket *midi) {
    
    if (subtick % (PPQ / 24) == 0) {
        if (sendMIDIClockStart) {
            for (int i = 0; i < 8; i++) {
                midi[i].data[0] = MIDI_CLOCK_START;
                midi[i].length++;
            }
            sendMIDIClockStart = false;
        } else {
            for (int i = 0; i < 8; i++) {
                midi[i].data[0] = MIDI_CLOCK;
                midi[i].length++;
            }
        }
    }
}

int64_t sampleTimeForNextSubtick(const double sampleRate,
                                 const double tempo,
                                 AUEventSampleTime sampleTime,
                                 const double beatPosition) {
    
    double transportTimeToNextBeat;
    if (ceil(beatPosition) == beatPosition) {
        transportTimeToNextBeat = 1;
    } else {
        transportTimeToNextBeat = ceil(beatPosition) - beatPosition;
    }
    
    double samplesToNextBeat = transportTimeToNextBeat * samplesPerBeat(sampleRate, tempo);
    double nextBeatSampleTime = sampleTime + samplesToNextBeat;
    int subticksLeftInBeat = PPQ - subtickPosition(beatPosition);
    
    return nextBeatSampleTime - (subticksLeftInBeat * samplesPerSubtick(sampleRate, tempo));
}

void CPSequencer::clearBuffers(MIDIPacket midiData[MIDI_PACKET_SIZE][8]) {
    
    // clear fifo buffer
    TPCircularBufferClear(&fifoBuffer);
    
    if (playingNotes.size() > 0) {
        // stop playing notes immediately
        for (int i = 0; i < playingNotes.size(); i++) {
            PlayingNote *note = &playingNotes[i];
            addPlayingNoteToMidiData(NOTE_OFF, 0, note, midiData[note->dest]);
        }
        playingNotes.clear();
    }
    
    // stop MIDI clock
    if (MIDIClockOn) {
        for (int i = 0; i < 4; i++) {
            for (int j = 0; j < 8; j++) {
                midiData[i][j].data[0] = MIDI_CLOCK_STOP;
                midiData[i][j].length++;
            }
        }
    }
    
    sendMIDIClockStart = true;
}

void CPSequencer::stopSequencer() {
    previousSegment = -1;
}

void CPSequencer::renderTimeline(const AUEventSampleTime now,
                                 SequencerSettings settings,
                                 const double beatPosition,
                                 MIDIPacket midiData[MIDI_PACKET_SIZE][8]) {
    
    double tempo = settings.tempo;
    double frameCount = settings.frameCount;
    double sampleRate = settings.sampleRate;
    
    MIDISequence sequence;
    sequence.length = 8.;
    //        sequence.eventCount = 2;
    //        sequence.events[0] = ev1;
    //        sequence.events[1] = ev2;
    //
    for (int i = 0; i < 8; i++) {
        MIDIEvent ev;
        ev.beatTime = (double)i * 0.25;
        ev.status = NOTE_ON;
        ev.data1 = 60;      // pitch
        ev.data2 = 110;     // velocity
        sequence.events[i] = ev;
    }
    
    sequence.eventCount = 8;
    
    // the length of the sequencer loop in musical time (e.g., 8.0 == 8 quarter notes)
    double lengthInSamples = sequence.length / tempo * 60. * sampleRate;
    double beatPositionInSamples = beatPosition / tempo * 60. * sampleRate;
    
    // the sample time at the start of the buffer, as given by the render block,
    // modulo the length of the sequencer loop
    double modPosition = fmod(beatPositionInSamples, lengthInSamples);
    // the buffer end time ('frameCount' is given by the render block)
    double bufferEndTime = modPosition + frameCount;
    
    for (int i = 0; i < sequence.eventCount; i++) {
        // the event timestamp, given in musical time (e.g., 1.25)
        MIDIEvent event = sequence.events[i];
        // convert the timestamp to sample time
        double eventTime = event.beatTime / tempo * 60. * sampleRate;
        
        bool noteOffIsInCurrentBuffer = eventTime >= modPosition && eventTime < bufferEndTime;
        bool loopsAround = (modPosition + frameCount > lengthInSamples) && eventTime <= bufferEndTime;
        
        // check if the event should occur within the current buffer
        if (noteOffIsInCurrentBuffer || loopsAround) {
            // the difference between the sample time of the event
            // and the beginning of the buffer gives us the offset, in samples
            double offset = eventTime - now;
            
            if (loopsAround) {
                int loopRestartInBuffer = (int)(lengthInSamples - now);
                eventTime = now + offset + loopRestartInBuffer;
            }
            if (event.status == NOTE_ON) {
                // TODO: schedule note on
//                printf("note on");
                addEventToMidiData(NOTE_ON, eventTime, &event, midiData[0]);
//                sendNoteOn(now + offset, event.data1, event.data2);
            } else if (event.status == NOTE_OFF) {
                // TODO: schedule note off
//                addPlayingNoteToMidiData(NOTE_OFF, eventTime, &event, midiData[0]);
//                printf("note off");
//                sendNoteOff(modPosition + offset, event.data1, event.data2);
            }
        }
    }
    
    // If you require sample-accurate sequencing, calculate your midi events based on the frame and buffer offsets
    
    for (int frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
        const int frameOffset = int(frameIndex + frameOffset);
        // Do sample-accurate sequencing here
        AUEventSampleTime timestamp = now + frameOffset;
        //            sendNoteOn(timestamp, 60, 120);
    }
    
//    double integral1;
//    double fractional1 = modf(beatPosition, &integral1);
//    const double position = ((int)integral1 % 64) + fractional1;
//
//    stopPlayingNotes(midiData[0], now, position, settings);
//
//    getMidiEventsFromFIFOBuffer();
//
//    for (int i = 0; i < SEQUENCE_COUNT; i++) {
//        MIDISequence sequence = sequences[i];
//
//        // check if beat transition occurs in current buffer
//        double length = sequence.length * sequence.playbackRatio;
//        int bufferStartTime = modPosition(position, length, settings);
//        long positionInSamples = beatToSamples(position, settings.tempo, settings.sampleRate);
//        printf("%ld\n", positionInSamples);
//        long lengthInSamples = beatToSamples(length, settings.tempo, settings.sampleRate);
//        int bufferEndTime = (bufferStartTime + settings.frameCount) % lengthInSamples;
//        int nextBeat = (int)floor(position / sequence.playbackRatio * 4.) % (int)(sequence.length * 4.);
//
//        // update UI
//        if (prevBeat[i] != nextBeat) {
//            if (callback) {
//                callback(nextBeat, i, callbackRefCon);
//            }
//            prevBeat[i] = nextBeat;
//        }
//
//        float swing = this->swing;
//        float swingGrid = 4.0;
//
//        // get events from sequence and check if they occur in the current buffer
//        for (int j = 0; j < sequence.eventCount; j++) {
//            MIDIEvent event = sequence.events[j];
//
//            double beatTime;
//
//            // add swing offset if necessary
//            double integral;
//            double fractional = modf(event.beatTime, &integral);
//            if (int(fractional * swingGrid) % 2 == 0) {
//                beatTime = event.beatTime;
//            } else {
//                beatTime = event.beatTime + (swing / swingGrid);
//            }
//
//            beatTime *= sequence.playbackRatio;
//            long eventOffset = beatToSamples(beatTime, settings.tempo, settings.sampleRate);
//
//            bool eventIsInCurrentBuffer = eventOffset >= bufferStartTime && eventOffset <= bufferEndTime;
//            // in case the sequence loops around we need to schedule it at the beginning of the next sequence...
//            bool loopsAround = (bufferStartTime + settings.frameCount > lengthInSamples) && eventOffset <= bufferEndTime;
//
//            bool mute = muteSequences[i];
//
//            bool solo = false;
//            for (int k = 0; k < SEQUENCE_COUNT; k++) {
//                if (soloSequences[k] == true && k != i) {
//                    solo = true;
//                    mute = false;   // solo overrides mute
//                }
//            }
//
//            if ((eventIsInCurrentBuffer || loopsAround) && mute == false && solo == false) {
//                switch (event.status) {
//                    case NOTE_ON: {
//                        // current event is ratcheted and shouldn't play based on chance
//                        if (event.isRatchet == true && chanceDidPlay == false) {
//                            break;
//                        }
//
//                        // throw a dice to determine if beat should be skipped
//                        uint32_t rand = arc4random_uniform(100);
//                        if (event.chance < rand && event.isRatchet == false) {
//                            chanceDidPlay = false;
//                            break;
//                        }
//
//                        chanceDidPlay = true;
//
//                        // check if note should be skipped
//                        if (event.skip > 0) {
//                            if (event.skipCount == 0) {
//                                // play note
//                                sequences[i].events[j].skipCount = event.skip;
//                            } else {
//                                // skip note
//                                sequences[i].events[j].skipCount -= 1;
//                                break;
//                            }
//                        }
//
//                        AUEventSampleTime eventTime = now + (eventOffset - bufferStartTime);
//                        // if the sequence loops around we need to calculate the
//                        // time for the first beat in the next loop
//                        if (loopsAround) {
//                            int loopRestartInBuffer = (int)(lengthInSamples - bufferStartTime);
//                            eventTime = now + eventOffset + loopRestartInBuffer;
//                        }
//
//                        // if there's a playing note with same pitch, stop it first
//                        for (int j = 0; j < playingNotes.size(); j++) {
//                            if (playingNotes[j].pitch == event.data1 &&
//                                !playingNotes[j].stopped) {
//
//                                // if so, send note off
//                                PlayingNote *note = &playingNotes[j];
//                                note->stopped = true;
//                                addPlayingNoteToMidiData(NOTE_OFF, eventTime, note, midiData[0]);
//                            }
//                        }
//
//
//                        addEventToMidiData(NOTE_ON, eventTime, &event, midiData[0]);
//
//                        // schedule note off
//                        double noteOffTime = beatTime + (event.duration * sequence.playbackRatio);
//                        if (noteOffTime >= length) {
//                            double integral;
//                            double fractional = modf(noteOffTime, &integral);
//                            noteOffTime = fractional;
//                        }
//
//                        PlayingNote noteOff;
//                        noteOff.pitch       = event.data1;
//                        noteOff.beatTime    = noteOffTime;
//                        noteOff.channel     = event.channel;
//                        noteOff.dest        = event.destination;
//                        noteOff.sequence    = event.sequenceIndex;
//                        noteOff.stopped     = false;
//                        playingNotes.push_back(noteOff);
//
//                        break;
//                    }
//                    case CC: {
//                        addEventToMidiData(CC, now + eventOffset, &event, midiData[0]);
//                        break;
//                    }
//                    case PITCH_BEND: {
//                        //                    addEventToMidiData(PITCH_BEND, ev, midiData[0]);
//                        break;
//                    }
//                }
//            }
//        }
//    }
}
