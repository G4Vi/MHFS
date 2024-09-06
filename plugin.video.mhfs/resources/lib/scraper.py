# -*- coding: utf-8 -*-
# KodiAddon (MHFS)
#
from t1mlib import t1mAddon
import json
import re
import xbmcplugin
import xbmcgui
import sys
import xbmc
import requests
import urllib.parse

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

class myAddon(t1mAddon):
  def __init__(self, aname):
      super().__init__(aname)
      mhfsurl = self.addon.getSetting('mhfsurl')
      if not mhfsurl.endswith('/'):
          mhfsurl = ''.join([mhfsurl, '/'])
      self.MHFSBASE = ''.join([mhfsurl, 'kodi/'])

  def getAddonMenu(self,url,ilist):
      eprint(''.join(['MHFSBASE ', self.MHFSBASE]))
      ilist = self.addMenuItem('TV', 'GS', ilist, "tv", videoInfo={'mediatype':'tvshow'})
      ilist = self.addMenuItem('Movies', 'GM', ilist, "movies", videoInfo={'mediatype':'movie'})
      return(ilist)

  def getAddonShows(self,url,ilist):
      fullurl = ''.join([self.MHFSBASE,url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedlist = sorted(a, key=lambda d: d['item'])
      for item in sortedlist:
          name = item['item']
          if item['isdir']:
              infoList = {'mediatype':'tvshow',
                         'TVShowTitle': name,
                         'Title': name}
              if 'plot' in item:
                  infoList['Plot'] = item['plot']
              thumb = ''.join([self.MHFSBASE, 'metadata/tv/thumb/', urllib.parse.quote(name)])
              fanart = ''.join([self.MHFSBASE, 'metadata/tv/fanart/', urllib.parse.quote(name)])
              ilist = self.addMenuItem(name,'GE', ilist, name, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=True)
          else:
              infoList = {'mediatype':'episode',
                          'Title': name,
                          'TVShowTitle': name}
              ilist = self.addMenuItem(name,'GV', ilist, name, videoInfo=infoList, isFolder=False)
      return(ilist)

  def getAddonEpisodes(self,url,ilist):
      fullurl = ''.join([self.MHFSBASE,'tv/', url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedlist = sorted(a, key=lambda d: d['item'])
      for item in sortedlist:
          name = item['item']
          newurl = ''.join(['tv/', urllib.parse.quote(url), '/', urllib.parse.quote(name)])
          eprint(newurl)
          if item['isdir']:
              infoList = {'mediatype':'tvshow',
                         'TVShowTitle': xbmc.getInfoLabel('ListItem.TVShowTitle'),
                         'Title': name}
              ilist = self.addMenuItem(name,'GE', ilist, newurl, videoInfo=infoList, isFolder=True)
          else:
              infoList = {'mediatype':'episode',
                          'Title': name,
                          'TVShowTitle': xbmc.getInfoLabel('ListItem.TVShowTitle')}
              ilist = self.addMenuItem(name,'GV', ilist, newurl, videoInfo=infoList, isFolder=False)
      return(ilist)

  def buildMovieMeta(self, displayname, moviename, movie):
      infoList = {'mediatype':'movie', 'Title': displayname}
      if 'year' in movie:
          infoList['Year'] = movie['year']
      if 'plot' in movie:
          infoList['Plot'] = movie['plot']
      thumb = ''.join([self.MHFSBASE, 'metadata/movies/thumb/', urllib.parse.quote(moviename)])
      fanart = ''.join([self.MHFSBASE, 'metadata/movies/fanart/', urllib.parse.quote(moviename)])
      return infoList, thumb, fanart

  def addMoviePart(self, displayname, ilist, moviename, movie, editionname, partname = ''):
      newurl = '/'.join(['movies', urllib.parse.quote(moviename), urllib.parse.quote(editionname)])
      if partname:
          subs = movie['editions'][editionname][partname].get('subs', [])
          if subs:
              newurl = ''.join([self.MHFSBASE, '/', newurl, '/'])
              newurl = json.dumps({'url': newurl, 'subs': subs, 'video': partname})
          else:
              newurl = '/'.join([newurl, urllib.parse.quote(partname)])
      infoList, thumb, fanart = self.buildMovieMeta(displayname, moviename, movie)
      return self.addMenuItem(displayname,'GV', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=False)

  def addMovieEdition(self, displayname, ilist, moviename, movie, editionname):
      edition = movie['editions'][editionname]
      if edition:
          if len(edition) > 1:
              newurl = json.dumps({'id': moviename, 'movie': movie, 'editionname': editionname})
              infoList, thumb, fanart = self.buildMovieMeta(displayname, moviename, movie)
              return self.addMenuItem(displayname,'GM', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList)
          else:
              partname = list(edition.keys())[0]
              return self.addMoviePart(displayname, ilist, moviename, movie, editionname, partname)
      return self.addMoviePart(displayname, ilist, moviename, movie, editionname)

  def getAddonMovies(self,url,ilist):
      if url.startswith('{'):
          item = json.loads(url)
          moviename = item['id']
          movie = item['movie']
          if 'editionname' in item:
              # add movie parts
              editionname = item['editionname']
              edition = movie['editions'][editionname]
              for partname in sorted(edition.keys()):
                  ilist = self.addMoviePart(partname, ilist, moviename, movie, editionname, partname)
          else:
              # add movie editions
              editionnames = sorted(movie['editions'].keys())
              for editionname in editionnames:
                  ilist = self.addMovieEdition(editionname, ilist, moviename, movie, editionname)
      elif url == 'movies':
          # add movies
          fullurl = ''.join([self.MHFSBASE,url,'/?fmt=json'])
          encoded = requests.get(fullurl, headers=self.defaultHeaders).text
          movies = json.loads(encoded)
          for moviename in sorted(movies.keys()):
              movie = movies[moviename]
              displayname = movie.get('name', moviename)
              if len(movie['editions']) == 1:
                  editionname = list(movie['editions'].keys())[0]
                  ilist = self.addMovieEdition(displayname, ilist, moviename, movie, editionname)
              else:
                  newurl = json.dumps({'id': moviename, 'movie': movie})
                  infoList, thumb, fanart = self.buildMovieMeta(displayname, moviename, movie)
                  ilist = self.addMenuItem(displayname,'GM', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList)
      return(ilist)

  def getAddonVideo(self,url):
      if not url.startswith('{'):
          subtitle_files = []
          newurl = ''.join([self.MHFSBASE, url])
      else:
          meta = json.loads(url)
          subtitle_files = list(map(lambda sub: meta['url'] + urllib.parse.quote(sub), meta['subs']))
          newurl = meta['url'] + urllib.parse.quote(meta['video'])
      liz = xbmcgui.ListItem(path = newurl, offscreen=True)
      if len(subtitle_files):
          liz.setSubtitles(subtitle_files)
      xbmcplugin.setResolvedUrl(int(sys.argv[1]), True, liz)
